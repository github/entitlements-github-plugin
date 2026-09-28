# frozen_string_literal: true

module Entitlements
  class Backend
    class GitHubRepository
      module Models
        class RepositoryAccess < Entitlements::Models::Group
          include ::Contracts::Core
          C = ::Contracts

          attr_reader :repository, :roles, :teams, :organization_access

          # Constructor.
          #
          # repository          - String with the repository name.
          # roles               - Hash mapping user logins to repository roles.
          # ou                  - String with the base OU for the repository DN.
          # teams               - Array of team grants returned by GitHub.
          # organization_access - Optional snapshot of organization-level access.
          Contract C::KeywordArgs[
            repository: String,
            roles: C::HashOf[String => String],
            ou: String,
            teams: C::Optional[C::ArrayOf[Hash]],
            organization_access: C::Optional[C::Maybe[OrganizationAccess]],
          ] => C::Any
          def initialize(repository:, roles:, ou:, teams: [], organization_access: nil)
            Configuration.validate_repository!(repository)
            @repository = repository
            @organization_access = organization_access
            @roles = {}
            @logins = {}
            roles.sort_by { |login, _| login.downcase }.each do |login, role|
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

          # Order direct team grants with parents before their children.
          #
          # Takes no arguments.
          #
          # Returns an Array of team grants. Cyclic hierarchies raise a backend error.
          Contract C::None => C::ArrayOf[Hash]
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

          # Select team grants assigned directly to the repository.
          #
          # Takes no arguments.
          #
          # Returns a Hash of team IDs mapped to grants.
          Contract C::None => C::HashOf[Integer => Hash]
          def direct_teams
            teams.select { |_, team| team[:access_source] == "direct" }
          end

          # Look up a user's direct repository role, ignoring login case.
          #
          # login - String with the user's GitHub login.
          #
          # Returns a repository role, or nil if the user has no direct grant.
          Contract String => C::Maybe[String]
          def role_for(login)
            roles[login.downcase]
          end

          # Look up the original spelling of a user's login.
          #
          # login - String with the user's GitHub login.
          #
          # Returns a String. Missing users raise KeyError.
          Contract String => String
          def login_for(login)
            @logins.fetch(login.downcase)
          end

          # Compare repository identities, direct grants and organization access.
          #
          # other - Object to compare with this snapshot.
          #
          # Returns true if the effective snapshots match.
          Contract C::Any => C::Bool
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
