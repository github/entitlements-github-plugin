# frozen_string_literal: true

require_relative "service"

require "set"
require "uri"

module Entitlements
  class Backend
    class GitHubOrg
      class Provider < Entitlements::Backend::BaseProvider
        include ::Contracts::Core
        C = ::Contracts

        attr_reader :github

        # Constructor.
        #
        # config - Configuration provided for the controller instantiation
        Contract C::KeywordArgs[
          config: C::HashOf[String => C::Any],
        ] => C::Any
        def initialize(config:)
          @github = Entitlements::Backend::GitHubOrg::Service.new(
            org: config.fetch("org"),
            addr: config.fetch("addr", nil),
            token: config.fetch("token"),
            ou: config.fetch("base")
          )
          @role_cache = {}
        end

        # Read in a github organization and enumerate its members and their roles. Results are cached
        # for future runs. The organization is defined per-entitlement as the `.org` method of the
        # github object.
        #
        # role_identifier - String with the role (a key from Entitlements::Backend::GitHubOrg::ORGANIZATION_ROLES) or a group.
        #
        # Returns a Entitlements::Models::Group object.
        Contract C::Or[String, Entitlements::Models::Group] => Entitlements::Models::Group
        def read(role_identifier)
          role_cn = role_name(role_identifier)
          @role_cache[role_cn] ||= role_to_group(role_cn)
        end

        # Commit changes.
        #
        # action - An Entitlements::Models::Action object.
        #
        # Returns true if a change was made, false if no change was made.
        Contract Entitlements::Models::Action => C::Bool
        def commit(action)
          # `false` usually means "What's going on, there are changes but nothing to apply!" Here it is
          # more routine that there are removals that are not processed (because adding to one role removes
          # from the other), so `true` is more accurate.
          return true unless action.implementation
          github.sync(action.implementation, role_name(action.updated))
        end

        # Invalidate the predictive cache.
        #
        # Takes no arguments.
        #
        # Returns nothing.
        Contract C::None => nil
        def invalidate_predictive_cache
          @role_cache = {}
          github.invalidate_org_members_predictive_cache
          nil
        end

        # Pending members.
        #
        # Takes no arguments.
        #
        # Returns Set of usernames.
        Contract C::None => C::SetOf[String]
        def pending_members
          github.pending_members
        end

        private

        # Determine the role name from a string or a group (with validation).
        #
        # role_identifier - String (a key from Entitlements::Backend::GitHubOrg::ORGANIZATION_ROLES) or a group.
        #
        # Returns a string with the role name.
        Contract C::Or[String, Entitlements::Models::Group] => String
        def role_name(role_identifier)
          role = Entitlements::Util::Util.any_to_cn(role_identifier)
          return role if Entitlements::Backend::GitHubOrg::ORGANIZATION_ROLES.key?(role)

          supported = Entitlements::Backend::GitHubOrg::ORGANIZATION_ROLES.keys.join(", ")
          message = "Invalid role #{role.inspect}. Supported values: #{supported}."
          raise ArgumentError, message
        end

        # Construct an Entitlements::Models::Group from a given role.
        #
        # role - A String with the role name.
        #
        # Returns an Entitlements::Models::Group object.
        Contract String => Entitlements::Models::Group
        def role_to_group(role)
          members = github.org_members.keys.select { |username| github.org_members[username] == role }
          Entitlements::Models::Group.new(
            dn: role_dn(role),
            members: Set.new(members),
            description: role_description(role)
          )
        end

        # Default description for a given role.
        #
        # role - A String with the role name.
        #
        # Returns a String with the default description for the role.
        Contract String => String
        def role_description(role)
          "Users with role #{role} on organization #{github.org}"
        end

        # Default distinguished name for a given role.
        #
        # role - A String with the role name.
        #
        # Returns a String with the distinguished name for the role.
        Contract String => String
        def role_dn(role)
          "cn=#{role},#{github.ou}"
        end
      end
    end
  end
end
