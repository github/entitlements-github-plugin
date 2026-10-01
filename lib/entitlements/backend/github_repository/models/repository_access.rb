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
            @repository = repository
            @organization_access = organization_access
            @roles, @logins = normalize_roles(roles)
            @teams = normalize_teams(teams)
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
              roots = root_teams(remaining)
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
          def ==(other)
            other.is_a?(self.class) && dn.casecmp?(other.dn) && roles == other.roles &&
              direct_teams == other.direct_teams && organization_access == other.organization_access
          end

          private

          # Normalize user roles and retain the original login spelling.
          Contract C::HashOf[String => String] => C::ArrayOf[Hash]
          def normalize_roles(roles)
            normalized_roles = {}
            logins = {}
            roles.sort_by { |login, _| login.downcase }.each do |login, role|
              GitHubRepository.fail!("Unsupported repository role: #{role.inspect}") unless ROLES.key?(role)
              key = login.downcase
              GitHubRepository.fail!("Duplicate repository user: #{login}") if normalized_roles.key?(key)
              normalized_roles[key] = role
              logins[key] = login
            end
            [normalized_roles.freeze, logins.freeze]
          end

          # Normalize and validate team grants for stable comparisons.
          Contract C::ArrayOf[Hash] => C::HashOf[Integer => Hash]
          def normalize_teams(teams)
            normalized = {}
            slugs = Set.new
            teams.each do |team|
              validate_team!(team)
              if normalized.key?(team[:id]) || !slugs.add?(team[:slug].downcase)
                GitHubRepository.fail!("Duplicate repository team: #{team[:slug]}")
              end
              normalized[team[:id]] = team.dup.freeze
            end
            normalized.freeze
          end

          # Validate a repository team grant.
          Contract C::Any => nil
          def validate_team!(team)
            valid = team.is_a?(Hash) && valid_team_identity?(team) &&
              valid_parent_id?(team[:parent_id]) && valid_access_source?(team[:access_source])
            GitHubRepository.fail!("Malformed repository team: #{team.inspect}") unless valid
          end

          # Select parentless teams relative to the remaining direct grants.
          Contract C::HashOf[Integer => Hash] => C::ArrayOf[Hash]
          def root_teams(remaining)
            remaining.values.reject { |team| remaining.key?(team[:parent_id]) }
              .sort_by { |team| team[:slug].downcase }
          end

          # Validate a team ID and slug.
          Contract Hash => C::Bool
          def valid_team_identity?(team)
            team[:id].is_a?(Integer) && team[:id].positive? &&
              team[:slug].is_a?(String) && /\A[a-zA-Z0-9_-]+\z/.match?(team[:slug])
          end

          # Validate an optional parent team ID.
          Contract C::Any => C::Bool
          def valid_parent_id?(parent_id)
            parent_id.nil? || (parent_id.is_a?(Integer) && parent_id.positive?)
          end

          # Validate a team access source.
          Contract C::Any => C::Bool
          def valid_access_source?(source)
            %w[direct organization enterprise].include?(source)
          end
        end
      end
    end
  end
end
