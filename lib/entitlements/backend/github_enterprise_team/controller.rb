# frozen_string_literal: true

module Entitlements
  class Backend
    class GitHubEnterpriseTeam
      class Controller < Entitlements::Backend::BaseController
        def self.priority
          40
        end

        register

        include ::Contracts::Core
        C = ::Contracts

        Contract String, C::Maybe[C::HashOf[String => C::Any]] => C::Any
        def initialize(group_name, config = nil)
          super
          @provider = Entitlements::Backend::GitHubEnterpriseTeam::Provider.new(config: @config)
        end

        def prefetch
          teams = Entitlements::Data::Groups::Calculated.read_all(group_name, config)
          teams.each do |team_slug|
            provider.read(Entitlements::Data::Groups::Calculated.read(team_slug))
          end
        end

        Contract C::None => C::Any
        def calculate
          changed = Entitlements::Data::Groups::Calculated.read_all(group_name, config).filter_map do |team_slug|
            group = Entitlements::Data::Groups::Calculated.read(team_slug)
            diff = provider.diff(group)

            if diff[:added].empty? && diff[:removed].empty?
              logger.debug "UNCHANGED: No GitHub enterprise team changes for #{group_name}:#{team_slug}"
              next
            end

            Entitlements::Models::Action.new(team_slug, provider.read(group), group, group_name)
          end

          print_differences(key: group_name, added: [], removed: [], changed:)
          @actions = changed
        end

        Contract Entitlements::Models::Action => C::Any
        def apply(action)
          unless action.updated.is_a?(Entitlements::Models::Group)
            logger.fatal "#{action.dn}: GitHub enterprise team membership cannot remove a team"
            raise RuntimeError, "Invalid Operation"
          end

          if provider.commit(action.updated)
            logger.debug "APPLY: Updating GitHub enterprise team #{action.dn}"
          else
            logger.warn "DID NOT APPLY: Changes not needed to #{action.dn}"
          end
        end

        Contract String, C::HashOf[String => C::Any] => nil
        def validate_config!(key, data)
          spec = COMMON_GROUP_CONFIG.merge({
            "addr"       => { required: false, type: String },
            "base"       => { required: true, type: String },
            "enterprise" => { required: true, type: String },
            "token"      => { required: true, type: String },
          })
          Entitlements::Util::Util.validate_attr!(spec, data, "GitHub enterprise team group #{key.inspect}")
        end

        private

        attr_reader :provider
      end
    end
  end
end
