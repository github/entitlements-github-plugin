# frozen_string_literal: true

module Entitlements
  class Backend
    class GitHubRepository
      class Controller < Entitlements::Backend::BaseController
        # Controller priority and registration
        def self.priority
          50
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
          @provider = Provider.new(config: @config)
        end

        # Validate configuration options.
        #
        # key  - String with the name of the group.
        # data - Hash with the configuration data.
        #
        # Returns nothing.
        Contract String, C::HashOf[String => C::Any] => nil
        def validate_config!(key, data)
          Configuration.validate!(key, data)
        end

        # Validate and load all local repository role files.
        #
        # Takes no arguments.
        #
        # Returns an Array of repository access models.
        Contract C::None => C::ArrayOf[Models::RepositoryAccess]
        def validate
          @repositories = Configuration.new(config).load
        end

        # Calculate changes after validating every local repository.
        #
        # Takes no arguments.
        #
        # Returns a list of @actions.
        Contract C::None => C::ArrayOf[Entitlements::Models::Action]
        def calculate
          # Evaluate every local file before making the first GitHub request.
          validate
          @actions = @repositories.filter_map { |repository| @provider.action_for(repository, group_name) }
        end

        # Apply changes.
        #
        # action - An Entitlements::Models::Action object.
        #
        # Returns nothing.
        Contract Entitlements::Models::Action => nil
        def apply(action)
          @provider.commit(action)
        end
      end
    end
  end
end
