# frozen_string_literal: true

require_relative "service"

require "set"
require "uri"

module Entitlements
  class Backend
    class GitHubTeam
      class Provider < Entitlements::Backend::BaseProvider
        include ::Contracts::Core
        C = ::Contracts

        # Constructor.
        #
        # config - Configuration provided for the controller instantiation
        Contract C::KeywordArgs[
          config: C::HashOf[String => C::Any],
        ] => C::Any
        def initialize(config:)
          @github = Entitlements::Backend::GitHubTeam::Service.new(
            org: config.fetch("org"),
            addr: config.fetch("addr", nil),
            token: config.fetch("token"),
            ou: config.fetch("base")
          )

          @github_team_cache = {}
        end

        # Read in a specific GitHub.com Team and enumerate its members. Results are cached
        # for future runs.
        #
        # team_identifier - Entitlements::Models::Group representing the entitlement
        #
        # Returns a Entitlements::Models::Group object representing the GitHub group or nil if the GitHub.com Team does not exist
        Contract Entitlements::Models::Group => C::Maybe[Entitlements::Models::Group]
        def read(entitlement_group)
          slug = Entitlements::Util::Util.any_to_cn(entitlement_group.cn.downcase)
          return @github_team_cache[slug] if @github_team_cache[slug]

          github_team = github.read_team(entitlement_group)

          # We should not cache a team which does not exist
          return nil if github_team.nil?

          Entitlements.logger.debug "Loaded #{github_team.team_dn} (id=#{github_team.team_id}) with #{github_team.member_strings.count} member(s)"
          @github_team_cache[github_team.team_name] = github_team
        end

        # Dry run of committing changes. Returns a list of users added or removed.
        #
        # group - An Entitlements::Models::Group object.
        #
        # Returns added / removed hash.
        Contract Entitlements::Models::Group, C::Maybe[C::SetOf[String]] => Hash[added: C::SetOf[String], removed: C::SetOf[String]]
        def diff(entitlement_group, ignored_users = Set.new)
          # The current value of the team from `read` might be based on the predictive cache
          # or on an actual API call. At this stage we don't care.
          team_identifier = entitlement_group.cn.downcase
          github_team_group = read(entitlement_group)
          if github_team_group.nil?
            github_team_group = create_github_team_group(entitlement_group)
          end

          result = diff_existing_updated(github_team_group, entitlement_group, ignored_users)

          # If there are no differences, return. (If we read from the predictive cache, we just saved ourselves a call
          # to the API. Hurray.)
          return result unless result[:added].any? || result[:removed].any? || result[:metadata]

          # If the group doesn't exist yet, we know we're not using the cache and we can save on any further API calls
          unless github_team_group.metadata_fetch_if_exists("team_id") == -999
            # There are differences so we don't want to use the predictive cache. Call to `from_predictive_cache?`
            # to determine whether our source of "current state" came from the predictive cache or from the API.
            # If it returns false, it came from the API, and we should just return what we got
            # (since pulling the data from the API again would be pointless).
            return result unless github.from_predictive_cache?(entitlement_group)

            # If `from_predictive_cache?` returned true, the data came from the predictive cache. We need
            # to invalidate the predictive cache entry, clean up the instance variable and re-read the refreshed data.
            github.invalidate_predictive_cache(entitlement_group)
            @github_team_cache.delete(team_identifier)
            github_team_group = read(entitlement_group)
          end

          # And finally, we have to calculate a new diff, which this time uses the fresh data from the API as
          # its basis, rather than the predictive cache.
          diff_existing_updated(github_team_group, entitlement_group, ignored_users)
        end

        # Dry run of committing changes. Returns a list of users added or removed and a hash explaining metadata changes
        # Takes an existing and an updated group object, avoiding a lookup in the backend.
        #
        # existing_group - An Entitlements::Models::Group object.
        # group          - An Entitlements::Models::Group object.
        # ignored_users  - Optionally, a Set of lower-case Strings of users to ignore.
        Contract Entitlements::Models::Group, Entitlements::Models::Group, C::Maybe[C::SetOf[String]] => Hash[added: C::SetOf[String], removed: C::SetOf[String], metadata: C::Maybe[Hash[]]]
        def diff_existing_updated(existing_group, group, ignored_users = Set.new)
          diff_existing_updated_metadata(existing_group, group, super)
        end

        # Determine if a change needs to be ignored. This will return true if the
        # user being added or removed is ignored.
        #
        # action - Entitlements::Models::Action object
        #
        # Returns true if the change should be ignored, false otherwise.
        Contract Entitlements::Models::Action => C::Bool
        def change_ignored?(action)
          return false if action.existing.nil?

          result = diff_existing_updated(action.existing, action.updated, action.ignored_users)
          result[:added].empty? && result[:removed].empty? && result[:metadata].nil?
        end

        # Commit changes.
        #
        # group - An Entitlements::Models::Group object.
        #
        # Returns true if a change was made, false if no change was made.
        Contract Entitlements::Models::Group => C::Bool
        def commit(entitlement_group)
          github_team = github.read_team(entitlement_group)

          # Create the new team and invalidate the cache
          if github_team.nil?
            team_name = entitlement_group.cn.downcase
            github.create_team(entitlement_group:)
            github.invalidate_predictive_cache(entitlement_group)
            @github_team_cache.delete(team_name)
            github_team = github.read_team(entitlement_group)
          end
          github.sync_team(entitlement_group, github_team)
        end

        # Automatically generate ignored users for a group. Find all members listed in the group who are not
        # admins or members of the GitHub organization in question.
        #
        # group - An Entitlements::Models::Group object.
        #
        # Returns a set of strings with usernames meeting the criteria.
        Contract Entitlements::Models::Group => C::SetOf[String]
        def auto_generate_ignored_users(entitlement_group)
          org_members = github.org_members.keys.map(&:downcase)
          group_members = entitlement_group.member_strings.map(&:downcase)
          Set.new(group_members - org_members)
        end

        private

        # Construct an Entitlements::Models::Group for a new group and team
        #
        # group - An Entitlements::Models::Group object representing the defined group
        #
        # Returns an Entitlements::Models::Group for a new group
        Contract Entitlements::Models::Group => Entitlements::Models::Group
        def create_github_team_group(entitlement_group)
          begin
            metadata = entitlement_group.metadata
            metadata["team_id"] = -999
          rescue Entitlements::Models::Group::NoMetadata
            metadata = {"team_id" => -999}
          end
          Entitlements::Backend::GitHubTeam::Models::Team.new(
            team_id: -999,
            team_name: entitlement_group.cn.downcase,
            members: Set.new,
            ou: github.ou,
            metadata:
          )
        end

        # Returns a diff hash of group metadata
        # Takes an existing and an updated group object, avoiding a lookup in the backend.
        #
        # existing_group - An Entitlements::Models::Group object.
        # group          - An Entitlements::Models::Group object.
        # base_diff  - Hash representing the base diff from diff_existing_updated
        Contract Entitlements::Models::Group, Entitlements::Models::Group, Hash[added: C::SetOf[String], removed: C::SetOf[String], metadata: C::Or[Hash[], nil]] => Hash[added: C::SetOf[String], removed: C::SetOf[String], metadata: C::Or[Hash[], nil]]
        def diff_existing_updated_metadata(existing_group, group, base_diff)
          if existing_group.metadata_fetch_if_exists("team_id") == -999
            base_diff[:metadata] = { create_team: true }
          end
          existing_parent_team = existing_group.metadata_fetch_if_exists("parent_team_name")
          changed_parent_team = group.metadata_fetch_if_exists("parent_team_name")

          if existing_parent_team != changed_parent_team
            if existing_parent_team.nil? && !changed_parent_team.nil?
              base_diff[:metadata] = { parent_team: "add" }
              Entitlements.logger.info "ADD github_parent_team #{changed_parent_team} to #{existing_group.dn} in #{github.org}"
            elsif !existing_parent_team.nil? && changed_parent_team.nil?
              base_diff[:metadata] = { parent_team: "remove" }
              Entitlements.logger.info "REMOVE (NOOP) github_parent_team #{existing_parent_team} from #{existing_group.dn} in #{github.org}"
            else
              base_diff[:metadata] = { parent_team: "change" }
              Entitlements.logger.info "CHANGE github_parent_team from #{existing_parent_team} to #{changed_parent_team} for #{existing_group.dn} in #{github.org}"
            end
          end

          existing_maintainers = existing_group.metadata_fetch_if_exists("team_maintainers")
          changed_maintainers = group.metadata_fetch_if_exists("team_maintainers")
          if existing_maintainers != changed_maintainers
            base_diff[:metadata] ||= {}
            if existing_maintainers.nil? && !changed_maintainers.nil?
              base_diff[:metadata][:team_maintainers] = "add"
              Entitlements.logger.info "ADD github_team_maintainers #{changed_maintainers} to #{existing_group.dn} in #{github.org}"
            elsif !existing_maintainers.nil? && changed_maintainers.nil?
              base_diff[:metadata][:team_maintainers] = "remove"
              Entitlements.logger.info "REMOVE (NOOP) github_team_maintainers #{existing_maintainers} from #{existing_group.dn} in #{github.org}"
            else
              base_diff[:metadata][:team_maintainers] = "change"
              Entitlements.logger.info "CHANGE github_team_maintainers from #{existing_maintainers} to #{changed_maintainers} for #{existing_group.dn} in #{github.org}"
            end
          end

          base_diff
        end

        attr_reader :github
      end
    end
  end
end
