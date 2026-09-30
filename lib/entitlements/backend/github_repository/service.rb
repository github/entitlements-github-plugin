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

        # Read organization membership from the snapshot populated by github_org reconciliation.
        #
        # Returns an organization access model.
        Contract C::None => Models::OrganizationAccess
        def organization_access
          @organization_access ||= begin
            # github_org runs first and seeds this shared cache. The inherited REST fallback
            # remains available when the repository backend is run independently.
            Models::OrganizationAccess.new(members: org_members, base_role: "none", assignments: {})
          end
        rescue Octokit::Error => e
          GitHubRepository.fail!("Reading organization membership for #{org} failed: #{e.message}")
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
            repository_collaborators(repository).each { |collaborator| read_collaborator(collaborator, roles) }
            Models::RepositoryAccess.new(repository: repository, roles: roles, teams: repository_teams(repository),
              organization_access: access, ou: ou)
          end
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

        # Read every direct repository collaborator.
        #
        # repository - String with the repository name.
        #
        # Returns an Array of collaborator resources.
        Contract String => C::ArrayOf[Sawyer::Resource]
        def repository_collaborators(repository)
          collaborators = octokit.collaborators("#{org}/#{repository}", affiliation: "direct")
          GitHubRepository.fail!("Malformed repository collaborators for #{repository}") unless collaborators.is_a?(Array)
          collaborators
        rescue Octokit::Error => e
          GitHubRepository.fail!("Reading collaborators for #{org}/#{repository} failed: #{e.message}")
        end

        # Validate a direct collaborator response and collect its repository role.
        #
        # collaborator - Unvalidated collaborator resource from GitHub.
        # roles        - Hash of user roles, updated in place.
        #
        # Returns the normalized direct role.
        Contract C::Any, C::HashOf[String => String] => String
        def read_collaborator(collaborator, roles)
          unless collaborator.is_a?(Sawyer::Resource) && collaborator[:login].is_a?(String) &&
              collaborator[:role_name].is_a?(String) && ROLES.key?(collaborator[:role_name].downcase)
            GitHubRepository.fail!("Malformed repository collaborator")
          end
          login = collaborator[:login]
          GitHubRepository.fail!("Duplicate repository collaborator: #{login}") if roles.keys.any? { |key| key.casecmp?(login) }
          roles[login] = collaborator[:role_name].downcase
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

      end
    end
  end
end
