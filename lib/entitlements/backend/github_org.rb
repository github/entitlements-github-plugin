# frozen_string_literal: true

module Entitlements
  class Backend
    class GitHubOrg
      include ::Contracts::Core
      C = ::Contracts

      # There are certain supported roles (which are mutually exclusive): admin, billing manager, member.
      # Define these in this one central place to be consumed everywhere.
      # The key is the name of the Entitlement, and that data is how this role appears on dotcom.
      ORGANIZATION_ROLES = {
        "admin"  => "ADMIN",
        # `billing-manager` is currently not supported
        "member" => "MEMBER",
        "security_manager" => "SECURITY-MANAGER"
      }

      # Error classes
      class DuplicateUserError < RuntimeError; end
    end
  end
end

require_relative "github_org/controller"
require_relative "github_org/provider"
require_relative "github_org/service"
