# frozen_string_literal: true

require_relative "github_org"
require_relative "../service/github"

module Entitlements
  class Backend
    class GitHubRepository
      ROLES = {
        "read" => "pull",
        "triage" => "triage",
        "write" => "push",
        "maintain" => "maintain",
        "admin" => "admin"
      }.freeze
      FEATURES = %w[add update remove].freeze

      class Error < RuntimeError; end

      def self.fail!(message)
        Entitlements.logger.error(message)
        raise Error, message
      end
    end
  end
end

require_relative "github_repository/models/repository_access"
require_relative "github_repository/configuration"
require_relative "github_repository/service"
require_relative "github_repository/provider"
require_relative "github_repository/controller"
