# frozen_string_literal: true

module Entitlements
  class Backend
    class GitHubRepository
      class Service < Entitlements::Service::GitHub
        include ::Contracts::Core
        C = ::Contracts

        # Read active organization members from the current access snapshot.
        #
        # Takes no arguments.
        #
        # Returns a Hash mapping user logins to membership roles.
        Contract C::None => C::HashOf[String => String]
        def active_members
          organization_access.members
        end

        # Read organization membership, base permissions and organization role assignments.
        #
        # Returns an organization access model.
        Contract C::None => Models::OrganizationAccess
        def organization_access
          @organization_access ||= begin
            # Organization reconciliation runs first, so keep one live, installation-specific
            # snapshot for every repository calculation and commit handled by this service.
            members = members_and_roles_from_rest.transform_values(&:downcase)
            organization = octokit.organization(org)
            GitHubRepository.fail!("Missing organization access settings for #{org}") unless organization.is_a?(Sawyer::Resource)
            base_role = organization[:default_repository_permission]
            data = octokit.get("orgs/#{org}/organization-roles")
            unless data.is_a?(Sawyer::Resource) && data[:roles].is_a?(Array) &&
                data[:total_count].is_a?(Integer) && data[:total_count] == data[:roles].length
              GitHubRepository.fail!("Incomplete organization role catalog for #{org}")
            end
            assignments = {}
            seen = Set.new
            data[:roles].each do |role|
              unless role.is_a?(Sawyer::Resource) && role[:id].is_a?(Integer) && role[:id].positive? &&
                  seen.add?(role[:id]) && role[:name].is_a?(String) && !role[:name].empty? &&
                  role.key?(:base_role) && (role[:base_role].nil? || ROLES.key?(role[:base_role])) &&
                  role[:permissions].is_a?(Array) && role[:permissions].all? { |permission| permission.is_a?(String) }
                GitHubRepository.fail!("Malformed organization role for #{org}")
              end
              grant = { id: role[:id], name: role[:name], base_role: role[:base_role], permissions: role[:permissions].sort.freeze }.freeze
              users = octokit.paginate("orgs/#{org}/organization-roles/#{role[:id]}/users")
              GitHubRepository.fail!("Malformed organization role assignments") unless users.is_a?(Array)
              logins = Set.new
              users.each do |user|
                unless user.is_a?(Sawyer::Resource) && %w[direct indirect mixed].include?(user[:assignment])
                  GitHubRepository.fail!("Malformed organization role assignee")
                end
                login = user[:login]
                GitHubRepository.fail!("Duplicate organization role assignee: #{login}") unless logins.add?(login.downcase)
                (assignments[login.downcase] ||= []) << grant
              end
            end
            Models::OrganizationAccess.new(members: members, base_role: base_role, assignments: assignments)
          end
        rescue Octokit::Error => e
          GitHubRepository.fail!("Reading organization access for #{org} failed: #{e.message}")
        end

        # Read direct user and team grants together with organization-level access.
        #
        # repository - String with the repository name.
        # refresh    - Boolean indicating whether to discard the cached repository access.
        #
        # Returns a repository access model.
        Contract String, C::KeywordArgs[refresh: C::Optional[C::Bool]] => Models::RepositoryAccess
        def read_repository(repository, refresh: false)
          @repositories ||= {}
          @repositories.delete(repository.downcase) if refresh
          @repositories[repository.downcase] ||= begin
            access = organization_access
            roles = {}
            cursor = nil
            cursors = Set.new
            loop do
              connection = collaborators(repository, cursor)
              connection.fetch("edges").each { |edge| read_edge(edge, roles, access) }
              page = connection.fetch("pageInfo")
              more = page.fetch("hasNextPage")
              GitHubRepository.fail!("Malformed repository pagination") unless [true, false].include?(more)
              break unless more
              cursor = page.fetch("endCursor")
              unless cursor.is_a?(String) && !cursor.empty? && cursors.add?(cursor)
                GitHubRepository.fail!("Missing or repeated repository pagination cursor")
              end
            end
            Models::RepositoryAccess.new(repository: repository, roles: roles, teams: repository_teams(repository),
              organization_access: access, ou: ou)
          end
        rescue KeyError, TypeError => e
          GitHubRepository.fail!("Malformed repository response for #{repository}: #{e.message}")
        end

        # Apply additions and updates before removals, invalidating the cached snapshot afterward.
        #
        # repository   - String with the repository name.
        # instructions - Array of user or team grant changes.
        # teams        - Optional fresh team snapshot from the preflight repository read.
        #
        # Returns the instructions in application order.
        Contract String, C::ArrayOf[Hash],
          C::KeywordArgs[teams: C::Optional[C::Maybe[C::ArrayOf[Hash]]]] => C::ArrayOf[Hash]
        def apply(repository, instructions, teams: nil)
          ordered = instructions.partition { |instruction| instruction.fetch(:action) == :upsert }.flatten
          team_snapshot = if ordered.any? { |instruction| instruction.fetch(:action) == :remove_team }
                            Models::RepositoryAccess.new(repository: repository, roles: {},
                              teams: teams || repository_teams(repository), ou: ou)
          end
          ordered.each do |instruction|
            if instruction.fetch(:action) == :remove_team
              remove_team(repository, instruction, team_snapshot)
              next
            end
            login = instruction.fetch(:login)
            if organization_access.owner?(login)
              GitHubRepository.fail!("#{repository}: direct grants for owner #{login} are deferred; recalculate")
            end
            if instruction.fetch(:action) == :upsert && !active_members.key?(login.downcase)
              GitHubRepository.fail!("#{repository}: #{login} is not an active organization member")
            end
            mutate(repository, instruction)
          end
        ensure
          # A partial apply must not leave a successful-looking cached snapshot.
          @repositories&.delete(repository.downcase)
        end

        private

        # Read team grants, preserving their access sources and parent relationships.
        #
        # repository - String with the repository name.
        #
        # Returns an Array of team grant hashes.
        Contract String => C::ArrayOf[Hash]
        def repository_teams(repository)
          teams = octokit.repository_teams("#{org}/#{repository}")
          GitHubRepository.fail!("Malformed repository teams for #{repository}") unless teams.is_a?(Array)
          teams.map do |team|
            unless team.is_a?(Sawyer::Resource) && team.key?(:parent) &&
                (team[:parent].nil? || (team[:parent].is_a?(Sawyer::Resource) && team[:parent][:id].is_a?(Integer)))
              GitHubRepository.fail!("Malformed repository team response for #{repository}")
            end
            source = team[:access_source]
            unless %w[direct organization enterprise].include?(source) && %w[organization enterprise].include?(team[:type]) &&
                (source != "direct" || team[:type] == "organization")
              GitHubRepository.fail!("Missing or unsupported repository team access_source")
            end
            { id: team[:id], slug: team[:slug], parent_id: team[:parent]&.[](:id), access_source: source }
          end
        rescue Octokit::Error => e
          GitHubRepository.fail!("Reading teams for #{org}/#{repository} failed: #{e.message}")
        end

        # Remove a direct team association after rechecking its identity and access source.
        #
        # repository  - String with the repository name.
        # instruction - Hash containing the team ID and slug.
        # current     - Fresh repository team snapshot used for every removal in this apply.
        #
        # Returns nothing.
        Contract String, C::HashOf[Symbol => C::Any], Models::RepositoryAccess => nil
        def remove_team(repository, instruction, current)
          team = current.teams[instruction.fetch(:team_id)]
          return unless team
          GitHubRepository.fail!("Repository team identity changed") unless team[:slug] == instruction.fetch(:slug)
          GitHubRepository.fail!("Repository team access source changed; recalculate") unless team[:access_source] == "direct"
          octokit.delete("orgs/#{org}/teams/#{team[:slug]}/repos/#{org}/#{repository}")
          GitHubRepository.fail!("Unexpected team removal response: HTTP #{octokit.last_response.status}") unless octokit.last_response.status == 204
        rescue Octokit::Error => e
          GitHubRepository.fail!("Removing team from #{org}/#{repository} failed: #{e.message}")
        end

        # Read one page of collaborators and their permission sources.
        #
        # repository - String with the repository name.
        # cursor     - Pagination cursor, or nil for the first page.
        #
        # Returns a Hash containing edges and pagination data.
        Contract String, C::Maybe[String] => C::HashOf[String => C::Any]
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

        # Validate a collaborator response and collect its direct repository role.
        #
        # edge   - Unvalidated collaborator edge from GitHub.
        # roles  - Hash of user roles, updated in place.
        # access - Organization access model used to exclude synthetic owner grants.
        #
        # Returns the direct role, or nil for inherited access.
        Contract C::Any, C::HashOf[String => String], Models::OrganizationAccess => C::Maybe[String]
        def read_edge(edge, roles, access)
          unless edge.is_a?(Hash) && edge["node"].is_a?(Hash) &&
              edge["permissionSources"].is_a?(Array) && !edge["permissionSources"].empty?
            GitHubRepository.fail!("Missing or malformed repository permission sources")
          end
          login = edge.fetch("node").fetch("login")
          direct = edge.fetch("permissionSources").select do |source|
            unless source.is_a?(Hash) && source["source"].is_a?(Hash)
              GitHubRepository.fail!("Malformed repository permission source")
            end
            type = source.fetch("source").fetch("__typename")
            unless %w[Repository Team Organization EnterpriseTeam].include?(type)
              GitHubRepository.fail!("Unknown repository permission source: #{type.inspect}")
            end
            type == "Repository"
          end
          # GitHub emits synthetic Repository admin sources for organization owners.
          return if access.owner?(login)
          return if direct.empty?
          GitHubRepository.fail!("Ambiguous direct repository permissions for #{login}") unless direct.size == 1
          role = direct.first.fetch("roleName")
          GitHubRepository.fail!("Unsupported direct repository role for #{login}: #{role.inspect}") unless role.is_a?(String) && ROLES.key?(role.downcase)
          GitHubRepository.fail!("Duplicate repository collaborator: #{login}") if roles.keys.any? { |key| key.casecmp?(login) }
          roles[login] = role.downcase
        end

        # Apply a direct user grant change and validate the HTTP response.
        #
        # repository  - String with the repository name.
        # instruction - Hash containing the action, login and optional permission.
        #
        # The return value is unused; failures raise a backend error.
        Contract String, C::HashOf[Symbol => C::Any] => C::Any
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

        # Determine the GraphQL endpoint for dotcom or GitHub Enterprise.
        #
        # Takes no arguments.
        #
        # Returns the endpoint URI.
        Contract C::None => URI::HTTP
        def graphql_uri
          @graphql_uri ||= URI.parse(octokit.api_endpoint.sub(%r{/api/v3/?\z}, "/api/").sub(%r{/?\z}, "/") + "graphql")
        end
      end
    end
  end
end
