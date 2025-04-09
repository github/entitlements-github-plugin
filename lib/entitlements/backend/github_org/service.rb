# frozen_string_literal: true

require_relative "../../service/github"

module Entitlements
  class Backend
    class GitHubOrg
      class Service < Entitlements::Service::GitHub
        include ::Contracts::Core
        C = ::Contracts

        # Sync the members of an organization in a given role to match the member list.
        #
        # implementation - An Hash of { action: :add/:remove, person: <person DN> }
        # role           - A String with the role, matching a key of Entitlements::Backend::GitHubOrg::ORGANIZATION_ROLES.
        #
        # Returns true if it succeeded, false if it did not.
        Contract C::ArrayOf[{ action: C::Or[:add, :remove], person: String }], String => C::Bool
        def sync(implementation, role)
          added_members = []
          removed_members = []

          implementation.each do |instruction|
            username = Entitlements::Util::Util.first_attr(instruction[:person]).downcase
            if instruction[:action] == :add
              added_members << username if add_user_to_organization(username, role)
            else
              removed_members << username if remove_user_from_organization(username)
            end
          end

          Entitlements.logger.debug "sync(#{role}): Added #{added_members.count}, removed #{removed_members.count}"
          added_members.any? || removed_members.any?
        end

        private

        Contract String, String => C::HashOf[Symbol, C::Any]
        def add_user_to_role(user, role)
          if role == "security_manager"
            octokit.add_role_to_user(user, role)

            # This is a hack to get around the fact that the GitHub API
            # has two different concepts of organization roles,
            # and the one we want to use is not present in organization memberships.
            #
            # If we get here, we know that the user is already member of the organization,
            # and we know that the user has been successfully granted the role.
            { user:, role:, state: "active" }
          else
            octokit.update_organization_membership(org, user:, role:)
          end
        end

        # Upsert a user with a role to the organization.
        #
        # user: A String with the (GitHub) username of the person to add or modify.
        # role: A String with the role, matching a key of Entitlements::Backend::GitHubOrg::ORGANIZATION_ROLES.
        #
        # Returns true if the user was added to the organization, false otherwise.
        Contract String, String => C::Bool
        def add_user_to_organization(user, role)
          Entitlements.logger.debug "#{identifier} add_user_to_organization(user=#{user}, org=#{org}, role=#{role})"

          begin
            new_membership = add_role_to_user(user, role)
          rescue Octokit::NotFound => e
            raise e unless ignore_not_found

            Entitlements.logger.warn "User #{user} not found in GitHub instance #{identifier}, ignoring."
            return false
          rescue Octokit::UnprocessableEntity => e
            # Two conditions can cause this:
            # - If the role is not enabled, we'll get a 422.
            # - If the user is not a member of the organization, we'll get a 422.

            # We'll loop this under ignore_not_found
            # since this affects the case where we want to add a user to security_manager role
            raise e unless ignore_not_found

            Entitlements.logger.warn "User #{user} not found in GitHub instance #{identifier}, ignoring."
            return false
          end

          # Happy path
          if new_membership[:role] == role
            if new_membership[:state] == "pending"
              pending_members.add(user)
              return true
            elsif new_membership[:state] == "active"
              org_members[user] = role
              return true
            end
          end

          Entitlements.logger.debug new_membership.inspect
          Entitlements.logger.error "Failed to adjust membership for #{user} in organization #{org} with role #{role}!"
          false
        end

        # Remove a user from the organization.
        #
        # user: A String with the (GitHub) username of the person to remove.
        #
        # Returns true if the user was removed, false otherwise.
        Contract String => C::Bool
        def remove_user_from_organization(user)
          Entitlements.logger.debug "#{identifier} remove_user_from_organization(user=#{user}, org=#{org})"
          result = octokit.remove_organization_membership(org, user:)

          # If we removed the user, remove them from the cache of members, so that any GitHub team
          # operations in this organization will ignore this user.
          if result
            org_members.delete(user)
            pending_members.delete(user)
          end

          # Return the result, true or false
          result
        end
      end
    end
  end
end
