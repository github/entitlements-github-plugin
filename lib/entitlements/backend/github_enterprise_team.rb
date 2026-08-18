# frozen_string_literal: true

require_relative "github_enterprise_team/controller"
require_relative "github_enterprise_team/provider"
require_relative "github_enterprise_team/service"
require_relative "github_team/models/team"
require_relative "../config/retry"

Retry.setup!
