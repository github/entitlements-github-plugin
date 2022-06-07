# frozen_string_literal: true

module Entitlements
  class Backend
    class GitHubTeam
      class Controller < Entitlements::Backend::BaseController
        # Controller priority and registration
        def self.priority
          40
        end

        register

        include ::Contracts::Core
        C = ::Contracts

        # Constructor. Generic constructor that takes a hash of configuration options.
        #
        # group_name - Name of the corresponding group in the entitlements configuration file.
        # config     - Optionally, a Hash of configuration information (configuration is referenced if empty).
        Contract String, C::Maybe[C::HashOf[String => C::Any]] => C::Any
        def initialize(group_name, config = nil)
          super
          @provider = Entitlements::Backend::GitHubTeam::Provider.new(config: @config)
        end

        def prefetch
          teams = Entitlements::Data::Groups::Calculated.read_all(group_name, config)
          teams.each do |team_slug|
            entitlement_group = Entitlements::Data::Groups::Calculated.read(team_slug)
            provider.read(entitlement_group)
          end
        end

        # Calculation routines.
        #
        # Takes no arguments.
        #
        # Returns a list of @actions.
        Contract C::None => C::Any
        def calculate
          added = []
          changed = []
          teams = Entitlements::Data::Groups::Calculated.read_all(group_name, config)
          teams.each do |team_slug|
            group = Entitlements::Data::Groups::Calculated.read(team_slug)

            # Anyone who is not a member of the organization is ignored in the diff calculation.
            # This avoids adding an organization membership for someone by virtue of adding them
            # to a team, without declaring them as an administrator or a member of the org. Also
            # this avoids having a pending member show up in diffs until they accept their invite.
            ignored_users = provider.auto_generate_ignored_users(group)

            # "diff" includes a call to GitHub API to read the team as it currently exists there.
            # Returns a hash { added: Set(members), removed: Set(members) }
            diff = provider.diff(group, ignored_users)

            if diff[:added].empty? && diff[:removed].empty? && diff[:metadata].nil?
              logger.debug "UNCHANGED: No GitHub team changes for #{group_name}:#{team_slug}"
              next
            end

            if diff[:metadata] && diff[:metadata][:create_team]
              added << Entitlements::Models::Action.new(team_slug, provider.read(group), group, group_name, ignored_users: ignored_users)
            else
              changed << Entitlements::Models::Action.new(team_slug, provider.read(group), group, group_name, ignored_users: ignored_users)
            end
          end
          print_differences(key: group_name, added: added, removed: [], changed: changed)

          @actions = added + changed
        end

        # Apply changes.
        #
        # action - Action array.
        #
        # Returns nothing.
        Contract Entitlements::Models::Action => C::Any
        def apply(action)
          unless action.updated.is_a?(Entitlements::Models::Group)
            logger.fatal "#{action.dn}: GitHub entitlements interface does not support removing a team at this point"
            raise RuntimeError, "Invalid Operation"
          end

          if provider.change_ignored?(action)
            logger.debug "SKIP: GitHub team #{action.dn} only changes organization non-members or pending members"
            return
          end

          if provider.commit(action.updated)
            logger.debug "APPLY: Updating GitHub team #{action.dn}"
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
        # :nocov:
        Contract String, C::HashOf[String => C::Any] => nil
        def validate_config!(key, data)
          spec = COMMON_GROUP_CONFIG.merge({
            "base"  => { required: true, type: String },
            "addr"  => { required: false, type: String },
            "org"   => { required: true, type: String },
            "token" => { required: true, type: String }
          })
          text = "GitHub group #{key.inspect}"
          Entitlements::Util::Util.validate_attr!(spec, data, text)
        end
        # :nocov:

        private

        attr_reader :provider
      end
    end
  end
end
