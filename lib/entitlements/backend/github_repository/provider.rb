# frozen_string_literal: true

module Entitlements
  class Backend
    class GitHubRepository
      class Provider < Entitlements::Backend::BaseProvider
        include ::Contracts::Core
        C = ::Contracts

        # Constructor.
        #
        # config - Configuration provided for the controller instantiation.
        Contract C::KeywordArgs[
          config: C::HashOf[String => C::Any],
        ] => C::Any
        def initialize(config:)
          @config = config
          @github = Service.new(org: config.fetch("org"), token: config.fetch("token"),
            ou: config.fetch("base"), addr: config["addr"])
        end

        # Read current access for the desired repository.
        #
        # desired - Repository access model containing the repository identity.
        #
        # Returns the current repository access model.
        Contract Models::RepositoryAccess => Models::RepositoryAccess
        def read(desired)
          @github.read_repository(desired.repository)
        end

        # Calculate direct grant changes without modifying inherited access.
        #
        # desired    - Repository access model containing the desired user roles.
        # group_name - Name of the corresponding group in the entitlements configuration file.
        #
        # Returns an action, or nil if no enabled changes are needed.
        Contract Models::RepositoryAccess, String => C::Maybe[Entitlements::Models::Action]
        def diff(desired, group_name)
          ignored = ignored_logins
          validate_members(desired, ignored)
          existing = read(desired)
          access = organization_access(existing)
          current = managed_roles(existing, ignored)
          target = managed_roles(desired, ignored)
          effective = current.dup
          instructions = user_instructions(desired, existing, current, target, access, effective)
          teams, team_instructions = team_changes(existing)
          instructions.concat(team_instructions)
          Entitlements.logger.info "#{desired.repository}: organization-level access and repository visibility are unchanged"
          return if instructions.empty?

          repository_action(desired, existing, current, effective, teams, instructions, group_name, ignored)
        end

        # Commit changes after checking for drift.
        #
        # action - An Entitlements::Models::Action object.
        #
        # Returns nothing.
        Contract Entitlements::Models::Action => nil
        def commit(action)
          GitHubRepository.fail!("Invalid repository action") unless valid_action?(action)
          current = @github.read_repository(action.updated.repository, refresh: true)
          unless filtered_snapshot(current, action.ignored_users) == action.existing
            GitHubRepository.fail!("Repository grants changed since calculation; recalculate before applying")
          end
          @github.sync_repository(action.updated.repository, action.implementation, teams: current.teams.values)
          nil
        end

        private

        # Return configured login exclusions in normalized form.
        Contract C::None => C::SetOf[String]
        def ignored_logins
          Set.new(@config.fetch("ignore", []).map(&:downcase))
        end

        # Read the organization access required for safe reconciliation.
        Contract Models::RepositoryAccess => Models::OrganizationAccess
        def organization_access(existing)
          access = existing.organization_access
          GitHubRepository.fail!("Missing organization access snapshot") unless access.is_a?(Models::OrganizationAccess)
          access
        end

        # Select the direct roles managed by this backend.
        Contract Models::RepositoryAccess, C::SetOf[String] => C::HashOf[String => String]
        def managed_roles(access, ignored)
          access.roles.reject { |login, _| ignored.include?(login) }
        end

        # Build direct collaborator instructions and update the effective role snapshot.
        Contract Models::RepositoryAccess, Models::RepositoryAccess, C::HashOf[String => String],
          C::HashOf[String => String], Models::OrganizationAccess, C::HashOf[String => String] => C::ArrayOf[Hash]
        def user_instructions(desired, existing, current, target, access, effective)
          (current.keys | target.keys).sort.filter_map do |login|
            user_instruction(login, desired, existing, current[login], target[login], access, effective)
          end
        end

        # Build one direct collaborator instruction when the change is safe and enabled.
        Contract String, Models::RepositoryAccess, Models::RepositoryAccess, C::Maybe[String],
          C::Maybe[String], Models::OrganizationAccess, C::HashOf[String => String] => C::Maybe[Hash]
        def user_instruction(login, desired, existing, before, after, access, effective)
          sources = access.sources(login)
          log_inherited_access(desired.repository, login, sources)
          return if deferred_change?(desired.repository, login, after, access, sources)
          return if before == after

          feature = change_feature(before, after)
          return unless enabled?(feature)

          instruction = collaborator_instruction(login, desired, existing, after)
          update_effective_roles!(effective, login, after)
          name = after ? desired.login_for(login) : existing.login_for(login)
          Entitlements.logger.info "CHANGE #{desired.repository}: #{name} #{before || '(none)'} -> #{after || '(none)'}"
          instruction
        end

        # Log organization access that remains after direct reconciliation.
        Contract String, String, C::ArrayOf[String] => C::Any
        def log_inherited_access(repository, login, sources)
          Entitlements.logger.info "#{repository}: #{login} retains #{sources.join(', ')}" unless sources.empty?
        end

        # Determine whether organization-level access makes a direct change ambiguous.
        Contract String, String, C::Maybe[String], Models::OrganizationAccess, C::ArrayOf[String] => C::Bool
        def deferred_change?(repository, login, desired_role, access, sources)
          inherited_role = access.inherited_role(login)
          return false unless access.owner?(login) || lower_role?(desired_role, inherited_role)

          Entitlements.logger.warn "DEFER #{repository}: #{login} direct role #{desired_role || '(none)'}; inherited #{inherited_role} via #{sources.join(', ')}; direct grants unchanged"
          true
        end

        # Determine whether the desired role is lower than inherited access.
        Contract C::Maybe[String], C::Maybe[String] => C::Bool
        def lower_role?(desired_role, inherited_role)
          !!(desired_role && inherited_role && ROLES.keys.index(desired_role) < ROLES.keys.index(inherited_role))
        end

        # Map a direct role transition to its feature flag.
        Contract C::Maybe[String], C::Maybe[String] => String
        def change_feature(before, after)
          return "add" if before.nil?
          return "remove" if after.nil?

          "update"
        end

        # Determine whether a reconciliation feature is enabled.
        Contract String => C::Bool
        def enabled?(feature)
          @config.fetch("features", FEATURES).include?(feature)
        end

        # Build a collaborator instruction using the original login spelling.
        Contract String, Models::RepositoryAccess, Models::RepositoryAccess, C::Maybe[String] => Hash
        def collaborator_instruction(login, desired, existing, role)
          return { action: :remove, login: existing.login_for(login) } unless role

          { action: :upsert, login: desired.login_for(login), permission: ROLES.fetch(role) }
        end

        # Update the predicted direct role snapshot after an enabled change.
        Contract C::HashOf[String => String], String, C::Maybe[String] => C::Any
        def update_effective_roles!(effective, login, role)
          role ? effective[login] = role : effective.delete(login)
        end

        # Plan direct team removals and preserve inherited team grants.
        Contract Models::RepositoryAccess => C::ArrayOf[C::Any]
        def team_changes(existing)
          instructions = enabled?("remove") ? team_removal_instructions(existing) : []
          warn_unenforced_team_policy(existing) unless enabled?("remove")
          log_preserved_teams(existing)
          remaining = enabled?("remove") ? inherited_teams(existing) : existing.teams.values
          [remaining, instructions]
        end

        # Build removal instructions for every direct team grant.
        Contract Models::RepositoryAccess => C::ArrayOf[Hash]
        def team_removal_instructions(existing)
          existing.ordered_teams.map do |team|
            Entitlements.logger.info "CHANGE #{existing.repository}: team #{@config.fetch('org')}/#{team[:slug]} (granted) -> (none)"
            { action: :remove_team, team_id: team[:id], slug: team[:slug] }
          end
        end

        # Warn when direct teams remain because removal is disabled.
        Contract Models::RepositoryAccess => C::Any
        def warn_unenforced_team_policy(existing)
          return if existing.direct_teams.empty?

          Entitlements.logger.warn("#{existing.repository}: remove disabled; individual-only repository grants are not enforced")
        end

        # Log inherited team access that this backend preserves.
        Contract Models::RepositoryAccess => C::Any
        def log_preserved_teams(existing)
          inherited_teams(existing).each do |team|
            Entitlements.logger.info "#{existing.repository}: preserving #{team[:access_source]} access for team #{@config.fetch('org')}/#{team[:slug]}"
            next unless team[:access_source] == "enterprise"

            Entitlements.logger.warn "#{existing.repository}: enterprise team #{team[:slug]} is unmanaged; individual-only policy is not fully enforced"
          end
        end

        # Select team grants inherited from organization or enterprise policy.
        Contract Models::RepositoryAccess => C::ArrayOf[Hash]
        def inherited_teams(existing)
          existing.teams.values.reject { |team| team[:access_source] == "direct" }
        end

        # Assemble the action with upserts ordered before removals.
        Contract Models::RepositoryAccess, Models::RepositoryAccess, C::HashOf[String => String],
          C::HashOf[String => String], C::ArrayOf[Hash], C::ArrayOf[Hash], String, C::SetOf[String] =>
          Entitlements::Models::Action
        def repository_action(desired, existing, current, effective, teams, instructions, group_name, ignored)
          action = Entitlements::Models::Action.new(desired.dn,
            snapshot(existing, current), snapshot(existing, effective, teams: teams), group_name, ignored_users: ignored)
          instructions.partition { |instruction| instruction[:action] == :upsert }.flatten.each do |instruction|
            action.add_implementation(instruction)
          end
          action
        end

        # Validate the shape and identity of an action before applying it.
        Contract Entitlements::Models::Action => C::Bool
        def valid_action?(action)
          action.existing.is_a?(Models::RepositoryAccess) && action.updated.is_a?(Models::RepositoryAccess) &&
            action.existing.dn == action.updated.dn && action.implementation.is_a?(Array)
        end

        # Copy a repository snapshot with the specified direct grants.
        #
        # source - Repository access model supplying the identity and organization access.
        # roles  - Hash mapping user logins to repository roles.
        # teams  - Array of team grants, defaulting to the source's teams.
        #
        # Returns a repository access model.
        Contract Models::RepositoryAccess, C::HashOf[String => String],
          C::KeywordArgs[teams: C::Optional[C::ArrayOf[Hash]]] => Models::RepositoryAccess
        def snapshot(source, roles, teams: source.teams.values)
          Models::RepositoryAccess.new(repository: source.repository, roles: roles, teams: teams,
            organization_access: source.organization_access, ou: @config.fetch("base"))
        end

        # Exclude ignored users from a repository snapshot.
        #
        # source  - Repository access model.
        # ignored - Set of lowercase user logins.
        #
        # Returns a repository access model.
        Contract Models::RepositoryAccess, C::SetOf[String] => Models::RepositoryAccess
        def filtered_snapshot(source, ignored)
          snapshot(source, source.roles.reject { |login, _| ignored.include?(login) })
        end

        # Reject nonmembers or add them to the ignored users when configured.
        #
        # desired - Repository access model containing the desired user roles.
        # ignored - Set of lowercase user logins, updated in place.
        #
        # Returns the updated Set, or nil if every non-ignored user is a member.
        Contract Models::RepositoryAccess, C::SetOf[String] => C::Maybe[C::SetOf[String]]
        def validate_members(desired, ignored)
          invalid = desired.roles.keys - @github.active_members.keys - ignored.to_a
          return if invalid.empty?
          message = "#{desired.repository}: not active organization members: #{invalid.join(', ')}"
          GitHubRepository.fail!(message) unless @config.fetch("ignore_not_found", false)
          Entitlements.logger.warn("#{message}; ignored")
          ignored.merge(invalid)
        end
      end
    end
  end
end
