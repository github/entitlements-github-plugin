# frozen_string_literal: true

module Entitlements
  class Backend
    class GitHubRepository
      module Models
        class RepositoryAccess < Entitlements::Models::Group
          attr_reader :repository, :roles, :teams, :organization_access

          def initialize(repository:, roles:, ou:, teams: [], organization_access: nil)
            Configuration.validate_repository!(repository)
            @repository = repository
            @organization_access = organization_access
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
            @teams = {}
            slugs = Set.new
            teams.each do |team|
              unless team.is_a?(Hash) && team[:id].is_a?(Integer) && team[:id].positive? &&
                  team[:slug].is_a?(String) && /\A[a-zA-Z0-9_-]+\z/.match?(team[:slug]) &&
                  %w[direct organization enterprise].include?(team[:access_source]) &&
                  (team[:parent_id].nil? || (team[:parent_id].is_a?(Integer) && team[:parent_id].positive?))
                GitHubRepository.fail!("Malformed repository team: #{team.inspect}")
              end
              if @teams.key?(team[:id]) || !slugs.add?(team[:slug].downcase)
                GitHubRepository.fail!("Duplicate repository team: #{team[:slug]}")
              end
              @teams[team[:id]] = team.dup.freeze
            end
            @teams.freeze
            ordered_teams
            super(dn: "cn=#{repository},#{ou}", members: Set.new(@logins.values))
          end

          def ordered_teams
            remaining = direct_teams.dup
            ordered = []
            until remaining.empty?
              roots = remaining.values.reject { |team| remaining.key?(team[:parent_id]) }.sort_by { |team| team[:slug].downcase }
              GitHubRepository.fail!("Cyclic repository team hierarchy") if roots.empty?
              roots.each { |team| ordered << remaining.delete(team[:id]) }
            end
            ordered
          end

          def direct_teams
            teams.select { |_, team| team[:access_source] == "direct" }
          end

          def role_for(login)
            roles[login.downcase]
          end

          def login_for(login)
            @logins.fetch(login.downcase)
          end

          def equals?(other)
            other.is_a?(self.class) && dn.casecmp?(other.dn) && roles == other.roles &&
              direct_teams == other.direct_teams && organization_access == other.organization_access
          end

          alias_method :==, :equals?
        end
      end
    end
  end
end
