# frozen_string_literal: true

module Entitlements
  class Backend
    class GitHubRepository
      class Service < Entitlements::Service::GitHub
        def active_members
          # Never use predictive membership to authorize a new direct grant.
          @active_members ||= begin
            invalidate_org_members_predictive_cache
            org_members.transform_keys(&:downcase).select { |_, role| role == "member" }
          end
        end

        def read_repository(repository, refresh: false)
          Configuration.validate_repository!(repository)
          @repositories ||= {}
          @repositories.delete(repository.downcase) if refresh
          @repositories[repository.downcase] ||= begin
            roles = {}
            cursor = nil
            cursors = Set.new
            loop do
              connection = collaborators(repository, cursor)
              connection.fetch("edges").each { |edge| read_edge(edge, roles) }
              page = connection.fetch("pageInfo")
              more = page.fetch("hasNextPage")
              GitHubRepository.fail!("Malformed repository pagination") unless [true, false].include?(more)
              break unless more
              cursor = page.fetch("endCursor")
              unless cursor.is_a?(String) && !cursor.empty? && cursors.add?(cursor)
                GitHubRepository.fail!("Missing or repeated repository pagination cursor")
              end
            end
            Models::RepositoryAccess.new(repository: repository, roles: roles, teams: repository_teams(repository), ou: ou)
          end
        rescue KeyError, TypeError => e
          GitHubRepository.fail!("Malformed repository response for #{repository}: #{e.message}")
        end

        def apply(repository, instructions)
          Configuration.validate_repository!(repository)
          instructions.partition { |instruction| instruction.fetch(:action) == :upsert }.flatten.each do |instruction|
            if instruction.fetch(:action) == :remove_team
              remove_team(repository, instruction)
              next
            end
            login = instruction.fetch(:login)
            Configuration.validate_login!(login)
            if instruction.fetch(:action) == :upsert && !active_members.key?(login.downcase)
              GitHubRepository.fail!("#{repository}: #{login} is not an active non-owner organization member")
            end
            mutate(repository, instruction)
          end
        ensure
          # A partial apply must not leave a successful-looking cached snapshot.
          @repositories&.delete(repository.downcase)
        end

        private

        def repository_teams(repository)
          teams = octokit.repository_teams("#{org}/#{repository}")
          GitHubRepository.fail!("Malformed repository teams for #{repository}") unless teams.is_a?(Array)
          teams.map do |team|
            unless team.is_a?(Sawyer::Resource) && team.key?(:parent) &&
                (team[:parent].nil? || (team[:parent].is_a?(Sawyer::Resource) && team[:parent][:id].is_a?(Integer)))
              GitHubRepository.fail!("Malformed repository team response for #{repository}")
            end
            { id: team[:id], slug: team[:slug], parent_id: team[:parent]&.[](:id) }
          end
        rescue Octokit::Error => e
          GitHubRepository.fail!("Reading teams for #{org}/#{repository} failed: #{e.message}")
        end

        def remove_team(repository, instruction)
          # Removing a parent association can also remove inherited child access.
          current = Models::RepositoryAccess.new(repository: repository, roles: {}, teams: repository_teams(repository), ou: ou)
          team = current.teams[instruction.fetch(:team_id)]
          return unless team
          GitHubRepository.fail!("Repository team identity changed") unless team[:slug] == instruction.fetch(:slug)
          octokit.delete("orgs/#{org}/teams/#{team[:slug]}/repos/#{org}/#{repository}")
          GitHubRepository.fail!("Unexpected team removal response: HTTP #{octokit.last_response.status}") unless octokit.last_response.status == 204
        rescue Octokit::Error => e
          GitHubRepository.fail!("Removing team from #{org}/#{repository} failed: #{e.message}")
        end

        def collaborators(repository, cursor)
          query = <<~GRAPHQL
            {
              repository(owner: #{JSON.generate(org)}, name: #{JSON.generate(repository)}) {
                collaborators(affiliation: DIRECT, first: 100, after: #{JSON.generate(cursor)}) {
                  edges {
                    node { login }
                    permissionSources { roleName source { __typename } }
                  }
                  pageInfo { hasNextPage endCursor }
                }
              }
            }
          GRAPHQL
          response = graphql_http_post(query)
          unless response[:code] == 200 && response[:data].is_a?(Hash) && !response[:data].key?("errors")
            GitHubRepository.fail!("Repository GraphQL query failed for #{org}/#{repository}: #{response.inspect}")
          end
          data = response[:data].fetch("data")
          repo = data.is_a?(Hash) && data["repository"]
          connection = repo.is_a?(Hash) && repo["collaborators"]
          unless connection.is_a?(Hash) && connection["edges"].is_a?(Array) && connection["pageInfo"].is_a?(Hash)
            GitHubRepository.fail!("Missing or malformed collaborator data for #{org}/#{repository}")
          end
          connection
        end

        def read_edge(edge, roles)
          unless edge.is_a?(Hash) && edge["node"].is_a?(Hash) && edge["permissionSources"].is_a?(Array)
            GitHubRepository.fail!("Missing or malformed repository permission sources")
          end
          login = edge.fetch("node").fetch("login")
          Configuration.validate_login!(login)
          direct = edge.fetch("permissionSources").select do |source|
            unless source.is_a?(Hash) && source["source"].is_a?(Hash)
              GitHubRepository.fail!("Malformed repository permission source")
            end
            type = source.fetch("source").fetch("__typename")
            unless %w[Repository Team Organization EnterpriseTeam].include?(type)
              GitHubRepository.fail!("Unknown repository permission source: #{type.inspect}")
            end
            GitHubRepository.fail!("Unsupported enterprise-team access for #{login}") if type == "EnterpriseTeam"
            type == "Repository"
          end
          return if direct.empty?
          GitHubRepository.fail!("Ambiguous direct repository permissions for #{login}") unless direct.size == 1
          role = direct.first.fetch("roleName")
          GitHubRepository.fail!("Unsupported direct repository role for #{login}: #{role.inspect}") unless role.is_a?(String) && ROLES.key?(role.downcase)
          GitHubRepository.fail!("Duplicate repository collaborator: #{login}") if roles.keys.any? { |key| key.casecmp?(login) }
          roles[login] = role.downcase
        end

        def mutate(repository, instruction)
          path = "repos/#{org}/#{repository}/collaborators/#{instruction.fetch(:login)}"
          action = instruction.fetch(:action)
          case action
          when :upsert
            permission = instruction.fetch(:permission)
            GitHubRepository.fail!("Unsupported REST repository permission: #{permission.inspect}") unless ROLES.value?(permission)
          when :remove
            permission = nil
          else
            GitHubRepository.fail!("Unknown repository instruction: #{action.inspect}")
          end
          # Octokit's middleware already retries server errors on idempotent requests.
          result = if action == :upsert
                     octokit.put(path, permission: permission)
          else
            octokit.delete(path)
          end
          status = octokit.last_response.status
          unless (action == :upsert ? [201, 204] : [204]).include?(status)
            GitHubRepository.fail!("Unexpected repository mutation response: HTTP #{status}")
          end
          if status == 201
            unless result.is_a?(Sawyer::Resource) && result[:id].is_a?(Integer) && result[:id] > 0
              GitHubRepository.fail!("Malformed repository invitation response")
            end
            Entitlements.logger.warn("#{repository}: invitation created for #{instruction.fetch(:login)}; access is not yet active")
          end
        rescue Octokit::Error => e
          GitHubRepository.fail!("#{action} #{org}/#{repository}/#{instruction.fetch(:login)} failed: #{e.message}")
        end

        def graphql_uri
          @graphql_uri ||= URI.parse(octokit.api_endpoint.sub(%r{/api/v3/?\z}, "/api/").sub(%r{/?\z}, "/") + "graphql")
        end
      end
    end
  end
end
