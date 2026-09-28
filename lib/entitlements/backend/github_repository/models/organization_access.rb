# frozen_string_literal: true
# Represents organization-level access that contributes to repository permissions.

module Entitlements
  class Backend
    class GitHubRepository
      module Models
        class OrganizationAccess
          include ::Contracts::Core
          C = ::Contracts

          attr_reader :members, :base_role, :assignments

          # Constructor.
          #
          # members     - Hash mapping organization member logins to membership roles.
          # base_role   - Default repository role from GitHub; missing or unsupported values are rejected.
          # assignments - Hash mapping user logins to Arrays of organization role grants.
          Contract C::KeywordArgs[
            members: C::HashOf[String => String],
            base_role: C::Maybe[String],
            assignments: C::HashOf[String => C::ArrayOf[Hash]],
          ] => C::Any
          def initialize(members:, base_role:, assignments:)
            unless (ROLES.keys + ["none"]).include?(base_role) &&
                members.values.all? { |role| %w[member admin].include?(role) }
              GitHubRepository.fail!("Malformed organization access")
            end
            @members = members.transform_keys(&:downcase).freeze
            @base_role = base_role
            @assignments = assignments.transform_keys(&:downcase).transform_values do |roles|
              roles.sort_by { |role| role.fetch(:id) }.freeze
            end.freeze
          end

          # Determine whether a user owns the organization.
          #
          # login - String with the user's GitHub login.
          #
          # Returns true for organization administrators.
          Contract String => C::Bool
          def owner?(login)
            members[login.downcase] == "admin"
          end

          # Find the highest repository role inherited through the organization.
          #
          # login - String with the user's GitHub login.
          #
          # Returns a repository role, or nil if there is no inherited role.
          Contract String => C::Maybe[String]
          def inherited_role(login)
            return unless members.key?(login.downcase)
            roles = assignments.fetch(login.downcase, []).filter_map { |assignment| assignment[:base_role] }
            roles << base_role unless base_role == "none"
            roles << "admin" if owner?(login)
            roles.max_by { |role| ROLES.keys.index(role) }
          end

          # Describe the organization grants contributing to a user's access.
          #
          # login - String with the user's GitHub login.
          #
          # Returns an Array of descriptions.
          Contract String => C::ArrayOf[String]
          def sources(login)
            result = assignments.fetch(login.downcase, []).map { |role| "organization role #{role.fetch(:name).inspect}" }
            result << "organization base #{base_role}" if members.key?(login.downcase) && base_role != "none"
            result << "organization ownership" if owner?(login)
            result
          end

          # Compare organization access snapshots.
          #
          # other - Object to compare with this snapshot.
          #
          # Returns true if membership, base permissions and assignments match.
          Contract C::Any => C::Bool
          def ==(other)
            other.is_a?(self.class) && members == other.members && base_role == other.base_role && assignments == other.assignments
          end
        end
      end
    end
  end
end
