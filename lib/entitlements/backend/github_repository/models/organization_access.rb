# frozen_string_literal: true

module Entitlements
  class Backend
    class GitHubRepository
      module Models
        class OrganizationAccess
          attr_reader :members, :base_role, :assignments

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

          def owner?(login)
            members[login.downcase] == "admin"
          end

          def inherited_role(login)
            return unless members.key?(login.downcase)
            roles = assignments.fetch(login.downcase, []).filter_map { |assignment| assignment[:base_role] }
            roles << base_role unless base_role == "none"
            roles << "admin" if owner?(login)
            roles.max_by { |role| ROLES.keys.index(role) }
          end

          def sources(login)
            result = assignments.fetch(login.downcase, []).map { |role| "organization role #{role.fetch(:name).inspect}" }
            result << "organization base #{base_role}" if members.key?(login.downcase) && base_role != "none"
            result << "organization ownership" if owner?(login)
            result
          end

          def ==(other)
            other.is_a?(self.class) && members == other.members && base_role == other.base_role && assignments == other.assignments
          end
        end
      end
    end
  end
end
