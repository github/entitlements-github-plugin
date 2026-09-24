# frozen_string_literal: true

module Entitlements
  class Backend
    class GitHubRepository
      module Models
        class RepositoryAccess < Entitlements::Models::Group
          attr_reader :repository, :roles

          def initialize(repository:, roles:, ou:)
            Configuration.validate_repository!(repository)
            @repository = repository
            @roles = {}
            @logins = {}
            roles.sort_by { |login, _| login.downcase }.each do |login, role|
              Configuration.validate_login!(login)
              GitHubRepository.fail!("Unsupported repository role: #{role.inspect}") unless ROLES.key?(role)
              key = login.downcase
              GitHubRepository.fail!("Duplicate repository user: #{login}") if @roles.key?(key)
              @roles[key] = role
              @logins[key] = login
            end
            @roles.freeze
            @logins.freeze
            super(dn: "cn=#{repository},#{ou}", members: Set.new(@logins.values))
          end

          def role_for(login)
            roles[login.downcase]
          end

          def login_for(login)
            @logins.fetch(login.downcase)
          end

          def equals?(other)
            other.is_a?(self.class) && dn.casecmp?(other.dn) && roles == other.roles
          end

          alias_method :==, :equals?
        end
      end
    end
  end
end
