# frozen_string_literal: true

require_relative "service"

module Entitlements
  class Backend
    class GitHubEnterpriseTeam
      class Provider < Entitlements::Backend::BaseProvider
        include ::Contracts::Core
        C = ::Contracts

        Contract C::KeywordArgs[
          config: C::HashOf[String => C::Any],
        ] => C::Any
        def initialize(config:)
          @github = Entitlements::Backend::GitHubEnterpriseTeam::Service.new(
            enterprise: config.fetch("enterprise"),
            addr: config.fetch("addr", nil),
            token: config.fetch("token"),
            ou: config.fetch("base")
          )
          @team_cache = {}
        end

        Contract Entitlements::Models::Group => Entitlements::Models::Group
        def read(entitlement_group)
          slug = Entitlements::Util::Util.any_to_cn(entitlement_group.cn.downcase)
          @team_cache[slug] ||= github.read_team(entitlement_group)
        end

        Contract Entitlements::Models::Group => Hash[added: C::SetOf[String], removed: C::SetOf[String]]
        def diff(entitlement_group)
          diff_existing_updated(read(entitlement_group), entitlement_group)
        end

        Contract Entitlements::Models::Group => C::Bool
        def commit(entitlement_group)
          github.sync_team(entitlement_group, read(entitlement_group))
        end

        private

        attr_reader :github
      end
    end
  end
end
