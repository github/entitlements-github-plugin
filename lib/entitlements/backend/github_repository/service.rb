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
        def sync_repository(repository, instructions, teams: nil)
          ordered = order_instructions(instructions)
          team_snapshot = team_snapshot(repository, ordered, teams)
          ordered.each { |instruction| apply_instruction(repository, instruction, team_snapshot) }
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
          teams.map { |team| normalize_team(repository, team) }
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
          validate_team_removal!(team, instruction)
          octokit.delete("orgs/#{org}/teams/#{team[:slug]}/repos/#{org}/#{repository}")
          validate_team_removal_response!
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
          GitHubRepository.fail!("Malformed repository collaborator") unless valid_collaborator?(collaborator)
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
        def apply_collaborator_instruction(repository, instruction)
          path = "repos/#{org}/#{repository}/collaborators/#{instruction.fetch(:login)}"
          action = instruction.fetch(:action)
          permission = collaborator_permission(action, instruction)
          # Octokit's middleware already retries server errors on idempotent requests.
          result = send_collaborator_request(path, action, permission)
          status = octokit.last_response.status
          validate_mutation_response!(repository, instruction, action, status, result)
        rescue Octokit::Error => e
          GitHubRepository.fail!("#{action} #{org}/#{repository}/#{instruction.fetch(:login)} failed: #{e.message}")
        end

        # Order additions and updates before destructive changes.
        Contract C::ArrayOf[Hash] => C::ArrayOf[Hash]
        def order_instructions(instructions)
          instructions.partition { |instruction| instruction.fetch(:action) == :upsert }.flatten
        end

        # Build the single fresh team snapshot shared by every team removal.
        Contract String, C::ArrayOf[Hash], C::Maybe[C::ArrayOf[Hash]] => C::Maybe[Models::RepositoryAccess]
        def team_snapshot(repository, instructions, teams)
          return unless instructions.any? { |instruction| instruction.fetch(:action) == :remove_team }

          Models::RepositoryAccess.new(repository: repository, roles: {},
            teams: teams || repository_teams(repository), ou: ou)
        end

        # Apply one user or team instruction.
        Contract String, C::HashOf[Symbol => C::Any], C::Maybe[Models::RepositoryAccess] => C::Any
        def apply_instruction(repository, instruction, current_teams)
          if instruction.fetch(:action) == :remove_team
            remove_team(repository, instruction, current_teams)
            return
          end

          validate_collaborator_target!(repository, instruction)
          apply_collaborator_instruction(repository, instruction)
        end

        # Reject owner and nonmember collaborator mutations.
        Contract String, C::HashOf[Symbol => C::Any] => nil
        def validate_collaborator_target!(repository, instruction)
          login = instruction.fetch(:login)
          if organization_access.owner?(login)
            GitHubRepository.fail!("#{repository}: direct grants for owner #{login} are deferred; recalculate")
          end
          return unless instruction.fetch(:action) == :upsert && !active_members.key?(login.downcase)

          GitHubRepository.fail!("#{repository}: #{login} is not an active organization member")
        end

        # Validate and normalize a repository team response.
        Contract String, C::Any => Hash
        def normalize_team(repository, team)
          unless valid_team_parent?(team)
            GitHubRepository.fail!("Malformed repository team response for #{repository}")
          end
          source = team[:access_source]
          GitHubRepository.fail!("Missing or unsupported repository team access_source") unless valid_team_source?(team, source)
          { id: team[:id], slug: team[:slug], parent_id: team[:parent]&.[](:id), access_source: source }
        end

        # Validate that a team removal still targets the planned direct grant.
        Contract Hash, C::HashOf[Symbol => C::Any] => nil
        def validate_team_removal!(team, instruction)
          GitHubRepository.fail!("Repository team identity changed") unless team[:slug] == instruction.fetch(:slug)
          return if team[:access_source] == "direct"

          GitHubRepository.fail!("Repository team access source changed; recalculate")
        end

        # Validate the HTTP response from a team removal.
        Contract C::None => nil
        def validate_team_removal_response!
          return if octokit.last_response.status == 204

          GitHubRepository.fail!("Unexpected team removal response: HTTP #{octokit.last_response.status}")
        end

        # Determine whether a team response has valid parent metadata.
        Contract C::Any => C::Bool
        def valid_team_parent?(team)
          team.is_a?(Sawyer::Resource) && team.key?(:parent) &&
            (team[:parent].nil? || (team[:parent].is_a?(Sawyer::Resource) && team[:parent][:id].is_a?(Integer)))
        end

        # Determine whether a team response identifies a supported access source.
        Contract Sawyer::Resource, C::Any => C::Bool
        def valid_team_source?(team, source)
          %w[direct organization enterprise].include?(source) &&
            %w[organization enterprise].include?(team[:type]) &&
            (source != "direct" || team[:type] == "organization")
        end

        # Determine whether a direct collaborator response has a supported role.
        Contract C::Any => C::Bool
        def valid_collaborator?(collaborator)
          collaborator.is_a?(Sawyer::Resource) && collaborator[:login].is_a?(String) &&
            collaborator[:role_name].is_a?(String) && ROLES.key?(collaborator[:role_name].downcase)
        end

        # Validate an instruction and return its REST permission.
        Contract Symbol, C::HashOf[Symbol => C::Any] => C::Maybe[String]
        def collaborator_permission(action, instruction)
          return if action == :remove
          GitHubRepository.fail!("Unknown repository instruction: #{action.inspect}") unless action == :upsert

          permission = instruction.fetch(:permission)
          GitHubRepository.fail!("Unsupported REST repository permission: #{permission.inspect}") unless ROLES.value?(permission)
          permission
        end

        # Send one collaborator mutation request.
        Contract String, Symbol, C::Maybe[String] => C::Any
        def send_collaborator_request(path, action, permission)
          return octokit.put(path, permission: permission) if action == :upsert

          octokit.delete(path)
        end

        # Validate the HTTP response from a collaborator mutation.
        Contract String, C::HashOf[Symbol => C::Any], Symbol, Integer, C::Any => nil
        def validate_mutation_response!(repository, instruction, action, status, result)
          expected_statuses = action == :upsert ? [201, 204] : [204]
          unless expected_statuses.include?(status)
            GitHubRepository.fail!("Unexpected repository mutation response: HTTP #{status}")
          end
          return unless status == 201

          validate_invitation!(result)
          Entitlements.logger.warn("#{repository}: invitation created for #{instruction.fetch(:login)}; access is not yet active")
        end

        # Validate a pending repository invitation response.
        Contract C::Any => nil
        def validate_invitation!(result)
          valid = result.is_a?(Sawyer::Resource) && result[:id].is_a?(Integer) && result[:id].positive?
          GitHubRepository.fail!("Malformed repository invitation response") unless valid
        end

      end
    end
  end
end
