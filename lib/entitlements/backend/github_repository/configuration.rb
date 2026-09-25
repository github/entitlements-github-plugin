# frozen_string_literal: true

module Entitlements
  class Backend
    class GitHubRepository
      class Configuration
        # Underscores are used by Enterprise Managed User logins.
        LOGIN = /\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/
        REPOSITORY = /\A[a-zA-Z0-9_.-]{1,100}\z/

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
          validate_login!(data.fetch("org"))
          { "features" => FEATURES, "allowed_types" => %w[txt yaml rb],
            "allowed_methods" => Entitlements::Data::Groups::Calculated.rules_index.keys }.each do |name, allowed|
            invalid = data.fetch(name, []) - allowed
            GitHubRepository.fail!("#{key}: invalid #{name}: #{invalid.inspect}") unless invalid.empty?
          end
          data.fetch("ignore", []).each { |login| validate_login!(login) }
          return if data["addr"].nil?

          uri = URI.parse(data.fetch("addr"))
          unless %w[http https].include?(uri.scheme) && uri.host && !uri.userinfo && !uri.query && !uri.fragment
            GitHubRepository.fail!("#{key}: addr must be an HTTP(S) API base URL without credentials, query or fragment")
          end
        rescue URI::InvalidURIError => e
          GitHubRepository.fail!("#{key}: invalid addr: #{e.message}")
        end

        def self.validate_login!(login)
          GitHubRepository.fail!("Invalid GitHub login: #{login.inspect}") unless login.is_a?(String) && LOGIN.match?(login)
        end

        def self.validate_repository!(repository)
          unless repository.is_a?(String) && REPOSITORY.match?(repository) && !%w[. ..].include?(repository)
            GitHubRepository.fail!("Invalid GitHub repository name: #{repository.inspect}")
          end
        end

        def initialize(config)
          @config = config
        end

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
              self.class.validate_login!(login)
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
