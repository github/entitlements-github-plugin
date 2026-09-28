# frozen_string_literal: true

module Entitlements
  class Backend
    class GitHubRepository
      class Configuration
        include ::Contracts::Core
        C = ::Contracts

        REPOSITORY = /\A[a-zA-Z0-9_.-]{1,100}\z/

        # Validate configuration options.
        #
        # key  - String with the name of the group.
        # data - Hash with the configuration data.
        #
        # Returns nothing.
        Contract String, C::HashOf[String => C::Any] => nil
        def self.validate!(key, data)
          spec = Entitlements::Backend::BaseController::COMMON_GROUP_CONFIG.merge(
            "dir" => { required: true, type: String },
            "base" => { required: true, type: String },
            "org" => { required: true, type: String },
            "token" => { required: true, type: String },
            "addr" => { required: false, type: [String, NilClass] },
            "features" => { required: false, type: Array },
            "ignore" => { required: false, type: Array },
            "ignore_not_found" => { required: false, type: [TrueClass, FalseClass] }
          )
          Entitlements::Util::Util.validate_attr!(spec, data, "GitHub repository backend #{key}")
          %w[dir base org token].each do |name|
            GitHubRepository.fail!("#{key}: #{name} must not be empty") if data.fetch(name).strip.empty?
          end
          { "features" => FEATURES, "allowed_types" => %w[txt yaml rb],
            "allowed_methods" => Entitlements::Data::Groups::Calculated.rules_index.keys }.each do |name, allowed|
            invalid = data.fetch(name, []) - allowed
            GitHubRepository.fail!("#{key}: invalid #{name}: #{invalid.inspect}") unless invalid.empty?
          end
          return if data["addr"].nil?

          uri = URI.parse(data.fetch("addr"))
          unless %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo && !uri.query && !uri.fragment
            GitHubRepository.fail!("#{key}: addr must be an HTTP(S) API base URL without credentials, query or fragment")
          end
        rescue URI::InvalidURIError => e
          GitHubRepository.fail!("#{key}: invalid addr: #{e.message}")
        end

        # Validate a repository name before using it in a path or API request.
        #
        # repository - Unvalidated repository name.
        #
        # Returns nothing. Invalid values raise a backend error.
        Contract C::Any => nil
        def self.validate_repository!(repository)
          unless repository.is_a?(String) && REPOSITORY.match?(repository) && !%w[. ..].include?(repository)
            GitHubRepository.fail!("Invalid GitHub repository name: #{repository.inspect}")
          end
        end

        # Constructor.
        #
        # config - Configuration provided for the controller instantiation.
        Contract C::HashOf[String => C::Any] => C::Any
        def initialize(config)
          @config = config
        end

        # Load the desired grants for every configured repository.
        #
        # Takes no arguments.
        #
        # Returns an Array of repository access models.
        Contract C::None => C::ArrayOf[Models::RepositoryAccess]
        def load
          root = File.expand_path(@config.fetch("dir"), Entitlements.config_path)
          seen = Set.new
          Dir.children(root).sort.map do |repository|
            self.class.validate_repository!(repository)
            path = File.join(root, repository)
            unless File.directory?(path) && !File.symlink?(path) && seen.add?(repository.downcase)
              GitHubRepository.fail!("Unexpected or duplicate repository directory: #{path}")
            end
            load_repository(repository, path)
          end
        end

        private

        # Evaluate a repository's role files using the standard rules engine.
        #
        # repository - String with the repository name.
        # path       - String with the absolute path to its role directory.
        #
        # Returns a repository access model.
        Contract String, String => Models::RepositoryAccess
        def load_repository(repository, path)
          roles = {}
          seen_roles = Set.new
          seen_users = Set.new
          Dir.children(path).sort.each do |entry|
            filename = File.join(path, entry)
            role = File.basename(entry, File.extname(entry))
            extension = File.extname(entry).delete_prefix(".")
            unless File.file?(filename) && !File.symlink?(filename) && ROLES.key?(role) &&
                @config.fetch("allowed_types", %w[txt yaml rb]).include?(extension) && seen_roles.add?(role)
              GitHubRepository.fail!("Unexpected or duplicate repository role file: #{filename}")
            end
            ruleset = Entitlements::Data::Groups::Calculated.ruleset(filename: filename, config: @config)
            ruleset.modified_filtered_members.each do |person|
              login = person.uid
              unless seen_users.add?(login.downcase)
                GitHubRepository.fail!("#{repository}: duplicate user across roles: #{login}")
              end
              roles[login] = role
            end
          end
          Models::RepositoryAccess.new(repository: repository, roles: roles, ou: @config.fetch("base"))
        end
      end
    end
  end
end
