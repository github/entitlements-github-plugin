# frozen_string_literal: true

# TL;DR: There are multiple shenanigans here, so please read this wall of text.
#
# This controller is different from many of the others because it has 2 mutually-exclusive entitlements that convey
# access to the same thing (a GitHub organization) with a different parameter (role). As such, this controller
# calculates the specific reconciliation actions and passes them along to the service. (Normally, the controller
# passes groups to the service, which figures out changes.) Taking the approach here allows less passing back and
# forth of data structures, such as "the set of all users we've seen".
#
# This controller also supports per-OU feature flags, settable in the configuration. It is possible to disable
# inviting new members to the organization, and removing old members from the organization, if there's already
# a process in place to manage that.
#
# Available features (defined in an array named `features` which can be empty):
# * invite: Invite a non-member to the organization
# * remove: Remove a non-member (or no-longer-known-to-entitlements user) from the organization
#
# If `features` is undefined, all available features will be applied. If you want to include neither of these features,
# set `features` to the empty array (`[]`) in the configuration. Note that moving an existing member of an organization
# from one role to another is always enabled, regardless of feature flag settings.
#
# But wait, there's even more. When a user gets added to a GitHub organization for the first time, they are not actually
# added to the member list right away, but instead they're invited and need to accept an invitation by e-mail before they
# show up in the list. We don't want to add (invite) a member via Entitlements and then have them showing up as a "needs
# to be added" diff on every single deploy until they accept the invitation. So, we will fudge an invited user to be
# "exactly the permissions Entitlements thinks they have" when they show up on the pending list. Unfortunately the pending
# list doesn't show whether they're invited as an admin or a member, so there's a potential gap between when they accept the
# invitation and the next Entitlements deploy where they could have the wrong privilege if they were invited as one thing
# but their role changed in Entitlements before they accepted the invite. This could be addressed by exposing their role
# on the pending member list in the GraphQL API.
#
# The mapping we need to implement looks like this:
#
# +-------------------+----------------+-----------------+----------------+----------------+
# |                   | Has admin role | Has member role | Pending invite | Does not exist |
# +-------------------+----------------+-----------------+----------------+----------------+
# | In "admin" group  |   No change    |      Move       |  Leave as-is   |    Invite      |
# +-------------------+----------------+-----------------+----------------+----------------+
# | In "member" group |     Move       |    No change    |  Leave as-is   |    Invite      |
# +-------------------+----------------+-----------------+----------------+----------------+
# | No entitlement    |    Remove      |     Remove      |  Cancel invite |      n/a       |
# +-------------------+----------------+-----------------+----------------+----------------+

module Entitlements
  class Backend
    class GitHubOrg
      class Controller < Entitlements::Backend::BaseController
        # Controller priority and registration
        def self.priority
          30
        end

        register

        include ::Contracts::Core
        C = ::Contracts

        AVAILABLE_FEATURES = %w[invite remove]
        DEFAULT_FEATURES = %w[invite remove]
        ROLES = Entitlements::Backend::GitHubOrg::ORGANIZATION_ROLES.keys.freeze

        # Constructor. Generic constructor that takes a hash of configuration options.
        #
        # group_name - Name of the corresponding group in the entitlements configuration file.
        # config     - Optionally, a Hash of configuration information (configuration is referenced if empty).
        Contract String, C::Maybe[C::HashOf[String => C::Any]] => C::Any
        def initialize(group_name, config = nil)
          super
          @provider = Entitlements::Backend::GitHubOrg::Provider.new(config: @config)
        end

        # Calculation routines.
        #
        # Takes no arguments.
        #
        # Returns a list of @actions.
        Contract C::None => C::Any
        def calculate
          @actions = []

          validate_github_org_ous! # calls read_all() for the OU
          validate_no_dupes!       # calls read() for each group

          if changes.any?
            print_differences(key: group_name, added: [], removed: [], changed: changes, ignored_users:)
            @actions.concat(changes)
          else
            logger.debug "UNCHANGED: No GitHub organization changes for #{group_name}"
          end
        end

        # Apply changes.
        #
        # action - Action array.
        #
        # Returns nothing.
        Contract Entitlements::Models::Action => C::Any
        def apply(action)
          unless action.existing.is_a?(Entitlements::Models::Group) && action.updated.is_a?(Entitlements::Models::Group)
            logger.fatal "#{action.dn}: GitHub entitlements interface does not support creating or removing a GitHub org"
            raise RuntimeError, "Invalid Operation"
          end

          if provider.commit(action)
            logger.debug "APPLY: Updating GitHub organization #{action.dn}"
          else
            logger.warn "DID NOT APPLY: Changes not needed to #{action.dn}"
            logger.debug "Old: #{action.existing.inspect}"
            logger.debug "New: #{action.updated.inspect}"
          end
        end

        # Validate configuration options.
        #
        # key  - String with the name of the group.
        # data - Hash with the configuration data.
        #
        # Returns nothing.
        Contract String, C::HashOf[String => C::Any] => nil
        def validate_config!(key, data)
          spec = COMMON_GROUP_CONFIG.merge({
            "base"     => { required: true, type: String },
            "addr"     => { required: false, type: String },
            "org"      => { required: true, type: String },
            "token"    => { required: true, type: String },
            "features" => { required: false, type: Array },
            "ignore"   => { required: false, type: Array }
          })
          text = "GitHub organization group #{key.inspect}"
          Entitlements::Util::Util.validate_attr!(spec, data, text)

          # Validate any features against the list of known features.
          if data["features"].is_a?(Array)
            invalid_flags = data["features"] - AVAILABLE_FEATURES
            if invalid_flags.any?
              raise "Invalid feature(s) in #{text}: #{invalid_flags.join(', ')}"
            end
          end
        end

        def prefetch
          existing_groups
        end

        private

        # Utility method to remove repetitive code. From a given hash (`added`, `moved`, `removed`), select
        # changes for the specified role, sort by username, and return an array of properly capitalized usernames.
        #
        # obj  - The hash (`added`, `moved`, `removed`)
        # role - The role to be selected
        #
        # Returns an Array of Strings.
        Contract C::HashOf[String => { member: String, role: String }], String => C::ArrayOf[String]
        def sorted_users_from_hash(obj, role)
          obj.select { |_, role_data| role_data[:role] == role }
             .sort_by { |username, _| username }        # Already downcased by the nature of the array
             .map { |_, role_data| role_data[:member] } # Member name with proper case
        end

        # Validate that each entitlement defines the correct roles (and only the correct roles).
        # Raise if this is not the case.
        #
        # Takes no arguments.
        #
        # Returns nothing (but, will raise an error if something is broken).
        Contract C::None => C::Any
        def validate_github_org_ous!
          updated = Entitlements::Data::Groups::Calculated.read_all(group_name, config)

          # If we are missing an expected role this is a fatal error.
          ROLES.each do |role|
            role_dn = ["cn=#{role}", config.fetch("base")].join(",")
            unless updated.member?(role_dn)
              logger.fatal "GitHubOrg: No group definition for #{group_name}:#{role} - abort!"
              raise "GitHubOrg must define admin and member roles."
            end
          end

          # If we have an unexpected role that's also an error.
          seen_roles = updated.map { |x| Entitlements::Util::Util.first_attr(x) }
          unexpected_roles = seen_roles - ROLES
          return unless unexpected_roles.any?

          logger.fatal "GitHubOrg: Unexpected role(s) in #{group_name}: #{unexpected_roles.join(', ')}"
          raise "GitHubOrg unexpected roles."
        end

        # Validate that within a given GitHub organization, a given person is not assigned to multiple
        # roles. Raise if a duplicate user is found.
        #
        # Takes no arguments.
        #
        # Returns nothing (but, will raise an error if something is broken).
        Contract C::None => C::Any
        def validate_no_dupes!
          users_seen = Set.new

          ROLES.each do |role|
            role_dn = ["cn=#{role}", config.fetch("base")].join(",")
            group = Entitlements::Data::Groups::Calculated.read(role_dn)

            users_set = Set.new(group.member_strings_insensitive)
            dupes = users_seen & users_set
            if dupes.empty?
              users_seen.merge(users_set)
            else
              message = "Users in multiple roles for #{group_name}: #{dupes.to_a.sort.join(', ')}"
              logger.fatal message
              raise Entitlements::Backend::GitHubOrg::DuplicateUserError, "Abort due to users in multiple roles"
            end
          end
        end

        def existing_groups
          @existing_groups ||= begin
            ROLES.map do |role|
              role_dn = ["cn=#{role}", config.fetch("base")].join(",")
              [role, provider.read(role_dn)]
            end.to_h
          end
        end

        # For a given OU, calculate the changes.
        #
        # Takes no arguments.
        #
        # Returns an array of change actions.
        Contract C::None => C::ArrayOf[Entitlements::Models::Action]
        def changes
          return @changes if @changes
          begin
            features = Set.new(config["features"] || DEFAULT_FEATURES)

            # Populate group membership into groups hash, so that these groups can be mutated later if users
            # are being ignored or organization membership is pending.
            groups = ROLES.map do |role|
              role_dn = ["cn=#{role}", config.fetch("base")].join(",")
              [role, Entitlements::Data::Groups::Calculated.read(role_dn)]
            end.to_h

            # Categorize changes by :added (invite user to organization), :moved (change a user's role), and
            # :removed (remove a user from the organization). This operates across all roles.
            chg = categorized_changes

            # Keep track of any actions needed to make changes.
            result = []

            # Get the pending members for the organization.
            pending = provider.pending_members

            # Handle pending members who are not in any entitlements groups (i.e. they were previously invited, but are
            # not in entitlements, so we need to cancel their invitation). We don't know from the query whether these users
            # are in the 'admin' or 'member' role, so just assign them to the member role. It really doesn't matter except
            # for display purposes because the net result is the same -- entitlements will see them as existing in the provider
            # but not supposed to exist so it will remove them.
            disinvited_users(groups, pending).each do |person_dn|
              existing_groups[ROLES.last].add_member(person_dn)
              chg[:removed][person_dn.downcase] = { member: person_dn, role: ROLES.last }
            end

            # For each role:
            # - Create actions respecting feature flags
            # - Hack changes to calculated membership if invite/remove is disabled by feature flag
            # - Calculate actions needed to make changes
            ROLES.each do |role|
              role_dn = ["cn=#{role}", config.fetch("base")].join(",")

              # Respecting feature flags, batch up the additions, move-ins, and removals in separate actions.
              # Note that "move-outs" are not tracked because moving in to one role automatically removes from
              # the existing role without an explicit API call for the removal.
              action = Entitlements::Models::Action.new(role_dn, existing_groups[role], groups[role], group_name)
              invited = sorted_users_from_hash(chg[:added], role)
              moved_in = sorted_users_from_hash(chg[:moved], role)
              removals = sorted_users_from_hash(chg[:removed], role)

              # If there are any `invited` members that are also `pending`, remove these from invited, and fake
              # them into the groups they are slated to join. This will make Entitlements treat this as a no-op
              # to avoid re-inviting these members.
              already_invited = remove_pending(invited, pending)
              already_invited.each do |person_dn|
                # Fake the member into their existing group so this does not show up as a change every time
                # that Entitlements runs.
                existing_groups[role].add_member(person_dn)
              end

              # `invited` are users who did not have any role in the organization before. Adding them to the
              # organization will generate an invitation that they must accept.
              if features.member?("invite")
                invited.each do |person_dn|
                  action.add_implementation({ action: :add, person: person_dn })
                end
              elsif invited.any?
                suppressed = invited.map { |k| Entitlements::Util::Util.first_attr(k) }.sort
                targets = [invited.size, invited.size == 1 ? "person:" : "people:", suppressed.join(", ")].join(" ")
                logger.debug "GitHubOrg #{group_name}:#{role}: Feature `invite` disabled. Not inviting #{targets}."

                invited.each do |person_dn|
                  # Remove the user from their new group so this does not show up as a change every time
                  # that Entitlements runs.
                  groups[role].remove_member(person_dn)
                end
              end

              # `moved_in` are users who exist in the organization but currently have a different role. Adding them
              # to the current role will also remove them from their old role (since a person can have exactly one role).
              # There is no feature flag to disable this action.
              moved_in.each do |person_dn|
                action.add_implementation({ action: :add, person: person_dn })
              end

              # `removals` are users who were in the organization but no longer are assigned to any role.
              # The resulting API call will remove the user from the organization.
              if features.member?("remove")
                removals.each do |person_dn|
                  action.add_implementation({ action: :remove, person: person_dn })
                end
              elsif removals.any?
                suppressed = removals.map { |k| Entitlements::Util::Util.first_attr(k) }.sort
                targets = [removals.size, removals.size == 1 ? "person:" : "people:", suppressed.join(", ")].join(" ")
                logger.debug "GitHubOrg #{group_name}:#{role}: Feature `remove` disabled. Not removing #{targets}."

                removals.each do |person_dn|
                  # Add the user back to their group so this does not show up as a change every time
                  # that Entitlements runs.
                  groups[role].add_member(person_dn)
                end
              end

              # re-diff with the modified groups to give accurate responses on whether there are changes.
              # Also, each move has an addition and a removal, but there's just one API call (the addition),
              # but for consistency we want the "diff" to show both the addition and the removal.
              diff = provider.diff(groups[role], ignored_users)

              if diff[:added].empty? && diff[:removed].empty?
                logger.debug "UNCHANGED: No GitHub organization changes for #{group_name}:#{role}"
                next
              end

              # Case-sensitize the existing members, which will be reporting all names in lower case because that's
              # how they come from the GitHub provider. If we have seen the member with correct capitalization,
              # replace the member entry with the correctly cased one. (There's no need to do this for the newly
              # invited members beause those won't show up in the group of existing members.)
              all_changes = chg[:moved].merge(chg[:removed])
              all_changes.each do |_, data|
                action.existing.update_case(data[:member])
              end

              result << action
            end

            # If there are changes, determine if the computed `org_members` are based on a predictive cache
            # or actual data from the API. If they are based on a predictive cache, then we need to invalidate
            # the predictive cache and repeat *all* of this logic with fresh data from the API. (We will just
            # call ourselves once the cache is invalidated to repeat.)
            if result.any? && provider.github.org_members_from_predictive_cache?
              provider.invalidate_predictive_cache
              result = changes
            else
              result
            end
          end

          @changes ||= result
          result
        end

        # For a given OU, translate the entitlement members into `invited`, `removed`, and `moved` hashes.
        #
        # Takes no arguments.
        #
        # Returns the structured hash of hashes, with keys :added, :removed, and :moved.
        Contract C::None => Hash[
          added: C::HashOf[String => Hash],
          removed: C::HashOf[String => Hash],
          moved: C::HashOf[String => Hash]
        ]
        def categorized_changes
          added = {}
          removed = {}
          moved = {}

          ROLES.each do |role|
            role_dn = ["cn=#{role}", config.fetch("base")].join(",")

            # Read the users calculated by Entitlements for this role.
            groups = Entitlements::Data::Groups::Calculated.read(role_dn)

            # "diff" makes a call to GitHub API to read the team as it currently exists there.
            # Returns a hash { added: Set(members), removed: Set(members) }
            diff = provider.diff(groups, ignored_users)

            # For comparison purposes we need to downcase the member DNs when populating the
            # `added`, `moved` and `removed` hashes. We need to store the original capitalization
            # for later reporting.
            diff[:added].each do |member|
              if removed.key?(member.downcase)
                # Already removed from a previous role. Therefore this is a move to a different role.
                removed.delete(member.downcase)
                moved[member.downcase] = { member:, role: }
              else
                # Not removed from a previous role. Suspect this is an addition to the org (if we later spot a removal
                # from a role, then the code below will update that to be a move instead).
                added[member.downcase] = { member:, role: }
              end
            end

            diff[:removed].each do |member|
              if added.key?(member.downcase)
                # Already added to a previous role. Therefore this is a move to a different role.
                moved[member.downcase] = added[member.downcase]
                added.delete(member.downcase)
              else
                # Not added to a previous role. Suspect this is a removal from the org (if we later spot an addition
                # to another role, then the code above will update that to be a move instead).
                removed[member.downcase] = { member:, role: }
              end
            end
          end

          { added:, removed:, moved: }
        end

        # Admins or members who are both `invited` and `pending` do not need to be re-invited. We're waiting for them
        # to accept their invitation but we don't want to re-invite them (and display a diff) over and over again
        # while we patiently wait for their acceptance. This method mutates `invited` and returns a set of pending
        # user distinguished names.
        #
        # invited - Set of correct-cased distinguished names (mutated)
        # pending - Set of lowercase GitHub usernames of pending members in an organization
        #
        # Returns a Set of correct-cased distinguished names removed from `invited` because they're pending.
        Contract C::ArrayOf[String], C::SetOf[String] => C::SetOf[String]
        def remove_pending(invited, pending)
          result = Set.new(invited.select { |k| pending.member?(Entitlements::Util::Util.first_attr(k).downcase) })
          invited.reject! { |item| result.member?(item) }
          result
        end

        # Given a list of groups and a list of pending members from the provider, determine which pending users are not
        # in any of the given groups. Return a list of these pending users (as distinguished names).
        #
        # groups  - Hash of calculated groups: { "role" => Entitlements::Models::Group }
        # pending - Set of Strings of pending usernames from GitHub
        #
        # Returns an Array of Strings with distinguished names.
        Contract C::HashOf[String => Entitlements::Models::Group], C::SetOf[String] => C::ArrayOf[String]
        def disinvited_users(groups, pending)
          all_users = groups.map do |_, grp|
            grp.member_strings.map { |ms| Entitlements::Util::Util.first_attr(ms).downcase }
          end.compact.flatten

          pending.to_a - all_users
        end

        def ignored_users
          @ignored_users ||= begin
            ignored_user_list = config["ignore"] || []
            Set.new(ignored_user_list.map(&:downcase))
          end
        end

        attr_reader :provider
      end
    end
  end
end
