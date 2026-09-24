# frozen_string_literal: true

module Entitlements
  class Backend
    class GitHubRepository
      class Controller < Entitlements::Backend::BaseController
        def self.priority
          50
        end

        register

        def initialize(group_name, config = nil)
          super
          @provider = Provider.new(config: @config)
        end

        def validate_config!(key, data)
          Configuration.validate!(key, data)
        end

        def validate
          @repositories = Configuration.new(config).load
        end

        def calculate
          # Evaluate every local file before making the first GitHub request.
          validate
          @actions = @repositories.filter_map { |repository| @provider.action_for(repository, group_name) }
        end

        def apply(action)
          @provider.commit(action)
        end
      end
    end
  end
end
