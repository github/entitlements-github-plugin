# frozen_string_literal: true

module Entitlements
  class Backend
    class GitHubRepository
      class Configuration
        include ::Contracts::Core
        C = ::Contracts

        REQUIRED_SETTINGS = %w[dir base org token].freeze
        DEFAULT_ALLOWED_TYPES = %w[txt yaml rb].freeze
        VALIDATION_SPEC = Entitlements::Backend::BaseController::COMMON_GROUP_CONFIG.merge(
          "dir" => { required: true, type: String },
          "base" => { required: true, type: String },
          "org" => { required: true, type: String },
          "token" => { required: true, type: String },
          "addr" => { required: false, type: [String, NilClass] },
          "features" => { required: false, type: Array },
          "ignore" => { required: false, type: Array },
          "ignore_not_found" => { required: false, type: [TrueClass, FalseClass] }
        ).freeze

        # Validate configuration options.
        #
        # key  - String with the name of the group.
        # data - Hash with the configuration data.
        #
        # Returns nothing.
        Contract String, C::HashOf[String => C::Any] => nil
        def self.validate!(key, data)
          Entitlements::Util::Util.validate_attr!(VALIDATION_SPEC, data, "GitHub repository backend #{key}")
          validate_required_settings!(key, data)
          validate_allowed_values!(key, data)
          validate_api_address!(key, data["addr"])
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
            filename, role = role_file(path, entry, seen_roles)
            add_role_members(repository, filename, role, roles, seen_users)
          end
          Models::RepositoryAccess.new(repository: repository, roles: roles, ou: @config.fetch("base"))
        end

        # Validate required settings that cannot be blank.
        Contract String, C::HashOf[String => C::Any] => nil
        def self.validate_required_settings!(key, data)
          REQUIRED_SETTINGS.each do |name|
            GitHubRepository.fail!("#{key}: #{name} must not be empty") if data.fetch(name).strip.empty?
          end
          nil
        end
        private_class_method :validate_required_settings!

        # Validate configured feature, file type and rule method allowlists.
        Contract String, C::HashOf[String => C::Any] => nil
        def self.validate_allowed_values!(key, data)
          allowed_values = {
            "features" => FEATURES,
            "allowed_types" => DEFAULT_ALLOWED_TYPES,
            "allowed_methods" => Entitlements::Data::Groups::Calculated.rules_index.keys,
          }
          allowed_values.each do |name, allowed|
            invalid = data.fetch(name, []) - allowed
            GitHubRepository.fail!("#{key}: invalid #{name}: #{invalid.inspect}") unless invalid.empty?
          end
          nil
        end
        private_class_method :validate_allowed_values!

        # Validate an optional GitHub API base URL.
        Contract String, C::Maybe[String] => nil
        def self.validate_api_address!(key, address)
          return if address.nil?

          uri = URI.parse(address)
          return if valid_api_address?(uri)

          GitHubRepository.fail!("#{key}: addr must be an HTTP(S) API base URL without credentials, query or fragment")
        rescue URI::InvalidURIError => e
          GitHubRepository.fail!("#{key}: invalid addr: #{e.message}")
        end
        private_class_method :validate_api_address!

        # Determine whether a parsed URI is an uncredentialed HTTP(S) API base.
        Contract URI::Generic => C::Bool
        def self.valid_api_address?(uri)
          %w[http https].include?(uri.scheme) && !uri.host.nil? &&
            uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?
        end
        private_class_method :valid_api_address?

        # Validate a role file and return its path and role.
        Contract String, String, C::SetOf[String] => C::ArrayOf[String]
        def role_file(path, entry, seen_roles)
          filename = File.join(path, entry)
          role = File.basename(entry, File.extname(entry))
          extension = File.extname(entry).delete_prefix(".")
          valid = File.file?(filename) && !File.symlink?(filename) && ROLES.key?(role) &&
            @config.fetch("allowed_types", DEFAULT_ALLOWED_TYPES).include?(extension) && seen_roles.add?(role)
          GitHubRepository.fail!("Unexpected or duplicate repository role file: #{filename}") unless valid
          [filename, role]
        end

        # Add the calculated members from one role file.
        Contract String, String, String, C::HashOf[String => String], C::SetOf[String] => C::Any
        def add_role_members(repository, filename, role, roles, seen_users)
          ruleset = Entitlements::Data::Groups::Calculated.ruleset(filename: filename, config: @config)
          ruleset.modified_filtered_members.each do |person|
            login = person.uid
            GitHubRepository.fail!("#{repository}: duplicate user across roles: #{login}") unless seen_users.add?(login.downcase)
            roles[login] = role
          end
        end
      end
    end
  end
end
