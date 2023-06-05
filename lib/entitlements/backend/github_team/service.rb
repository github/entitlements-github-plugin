# frozen_string_literal: true

require_relative "models/team"
require_relative "../../service/github"

require "base64"

module Entitlements
  class Backend
    class GitHubTeam
      class Service < Entitlements::Service::GitHub
        include ::Contracts::Core
        include ::Contracts::Builtin
        C = ::Contracts

        class TeamNotFound < RuntimeError; end

        # Constructor.
        #
        # addr   - Base URL a GitHub Enterprise API (leave undefined to use dotcom)
        # org    - String with organization name
        # token  - Access token for GitHub API
        # ou     - Base OU for fudged DNs
        #
        # Returns nothing.
        Contract C::KeywordArgs[
          addr: C::Maybe[String],
          org: String,
          token: String,
          ou: String
        ] => C::Any
        def initialize(addr: nil, org:, token:, ou:)
          super
          Entitlements.cache[:github_team_members] ||= {}
          Entitlements.cache[:github_team_members][org] ||= {}
          @team_cache = Entitlements.cache[:github_team_members][org]
        end

        # Read a single team identified by its slug and return a team object.
        # This is aware of the predictive cache and will use it if appropriate.
        #
        # entitlement_group - Entitlements::Models::Group representing the entitlement being worked on
        #
        # Returns a Entitlements::Backend::GitHubTeam::Models::Team or nil if the team does not exist
        Contract Entitlements::Models::Group => C::Maybe[Entitlements::Backend::GitHubTeam::Models::Team]
        def read_team(entitlement_group)
          team_identifier = entitlement_group.cn.downcase
          @team_cache[team_identifier] ||= begin
            dn = "cn=#{team_identifier},#{ou}"
            begin
              entitlement_metadata = entitlement_group.metadata
            rescue Entitlements::Models::Group::NoMetadata
              entitlement_metadata = nil
            end

            if (cached_members = Entitlements::Data::Groups::Cached.members(dn))
              Entitlements.logger.debug "Loading GitHub team #{identifier}:#{org}/#{team_identifier} from cache"

              cached_metadata = Entitlements::Data::Groups::Cached.metadata(dn)
              # If both the cached and entitlement metadata are nil, our team metadata is nil
              # If one of the cached or entitlement metadata is nil, we use the other populated metadata hash as-is
              # If both cached and entitlement metadata exist, we combine the two hashes with the cached metadata taking precedence
              #
              # The reason we do this is because an entitlement file should be 1:1 to a GitHub Team. However,
              # entitlements files allow for metadata tags and the GitHub.com Team does not have a place to store those.
              # Therefore, we must combine any existing entitlement metadata entries into the Team metadata hash
              if cached_metadata.nil?
                team_metadata = entitlement_metadata
              elsif entitlement_metadata.nil?
                team_metadata = cached_metadata
              else
                # Always merge the current state metadata (cached or API call) into the entitlement metadata, so that the current state takes precedent
                team_metadata = entitlement_metadata.merge(cached_metadata)
              end

              team = Entitlements::Backend::GitHubTeam::Models::Team.new(
                team_id: -1,
                team_name: team_identifier,
                members: cached_members,
                ou: ou,
                metadata: team_metadata
              )

              { cache: true, value: team }
            else
              Entitlements.logger.debug "Loading GitHub team #{identifier}:#{org}/#{team_identifier}"

              begin
                teamdata = graphql_team_data(team_identifier)
                # The entitlement metadata may have GitHub.com Team metadata which it wants to set, so we must
                # overwrite that metadata with what we get from the API
                if teamdata[:parent_team_name].nil?
                  team_metadata = entitlement_metadata
                else
                  parent_team_metadata = {
                    "parent_team_name" => teamdata[:parent_team_name]
                  }
                  if entitlement_metadata.nil?
                    team_metadata = parent_team_metadata
                  else
                    # Always merge the current state metadata (cached or API call) into the entitlement metadata, so that the current state takes precedent
                    team_metadata = entitlement_metadata.merge(parent_team_metadata)
                  end
                end

                team = Entitlements::Backend::GitHubTeam::Models::Team.new(
                  team_id: teamdata[:team_id],
                  team_name: team_identifier,
                  members: Set.new(teamdata[:members]),
                  ou: ou,
                  metadata: team_metadata
                )
              rescue TeamNotFound
                Entitlements.logger.warn "Team #{team_identifier} does not exist in this GitHub.com organization. If applied, the team will be created."
                return nil
              end

              { cache: false, value: team }
            end
          end

          @team_cache[team_identifier][:value]
        end

        # Determine whether the most recent entry came from the predictive cache or an actual
        # call to the API.
        #
        # entitlement_group - Entitlements::Models::Group representing the group from the entitlement
        #
        # Returns true if it came from the cache, or false if it came from the API.
        Contract Entitlements::Models::Group => C::Bool
        def from_predictive_cache?(entitlement_group)
          team_identifier = entitlement_group.cn.downcase
          read_team(entitlement_group) unless @team_cache[team_identifier]
          (@team_cache[team_identifier] && @team_cache[team_identifier][:cache]) ? true : false
        end

        # Declare the entry to be invalid for a specific team, and if the prior knowledge
        # of that team was from the cache, re-read from the actual data source.
        #
        # entitlement_group - Entitlements::Models::Group representing the group from the entitlement
        #
        # Returns nothing.
        Contract Entitlements::Models::Group => nil
        def invalidate_predictive_cache(entitlement_group)
          # If the entry was not from the predictive cache in the first place, just return.
          # This really should not get called if that's the case, but regardless, we don't
          # want to pointlessly hit the API twice.
          return unless from_predictive_cache?(entitlement_group)

          # The entry did come from the predictive cache. Clear out all of the local caches
          # in this object and re-read the data from the API.
          team_identifier = entitlement_group.cn.downcase
          dn = "cn=#{team_identifier},#{ou}"
          Entitlements.logger.debug "Invalidating cache entry for #{dn}"
          Entitlements::Data::Groups::Cached.invalidate(dn)
          @team_cache.delete(team_identifier)
          read_team(entitlement_group)
          nil
        end

        # Sync a GitHub team. (The team must already exist and its ID must be known.)
        #
        # data - An Entitlements::Backend::GitHubTeam::Models::Team object with the new members and data.
        #
        # Returns true if it succeeded, false if it did not.
        Contract Entitlements::Models::Group, C::Or[Entitlements::Backend::GitHubTeam::Models::Team, nil] => C::Bool
        def sync_team(desired_state, current_state)
          begin
            desired_metadata = desired_state.metadata
          rescue Entitlements::Models::Group::NoMetadata
            desired_metadata = {}
          end

          begin
            current_metadata = current_state.metadata
          rescue Entitlements::Models::Group::NoMetadata, NoMethodError
            current_metadata = {}
          end

          changed_parent_team = false
          unless desired_metadata["parent_team_name"] == current_metadata["parent_team_name"]
            # TODO: I'm hard-coding a block for deletes, for now. I'm doing that by making sure we dont set the desired parent_team_id to nil for teams where it is already set
            # :nocov:
            if desired_metadata["parent_team_name"].nil?
              Entitlements.logger.debug "sync_team(team=#{current_state.team_name}): IGNORING GitHub Parent Team DELETE"
            else
            # :nocov:
              Entitlements.logger.debug "sync_team(#{current_state.team_name}=#{current_state.team_id}): Parent team change found - From #{current_metadata["parent_team_name"] || "No Parent Team"} to #{desired_metadata["parent_team_name"]}"
              desired_parent_team_id = team_by_name(org_name: org, team_name: desired_metadata["parent_team_name"])[:id]
              unless desired_parent_team_id.nil?
                # TODO: I'm hard-coding a block for deletes, for now. I'm doing that by making sure we dont set the desired parent_team_id to nil for teams where it is already set
                update_team(team: current_state, metadata: { parent_team_id: desired_parent_team_id })
              end
              changed_parent_team = true
            end
          end

          added_members = desired_state.member_strings.map { |u| u.downcase } - current_state.member_strings.map { |u| u.downcase }
          removed_members = current_state.member_strings.map { |u| u.downcase } - desired_state.member_strings.map { |u| u.downcase }

          added_members.select! { |username| add_user_to_team(user: username, team: current_state) }
          removed_members.select! { |username| remove_user_from_team(user: username, team: current_state) }

          Entitlements.logger.debug "sync_team(#{current_state.team_name}=#{current_state.team_id}): Added #{added_members.count}, removed #{removed_members.count}"
          added_members.any? || removed_members.any? || changed_parent_team
        end

        # Create a team
        #
        # team - String with the desired team name
        #
        # Returns true if the team was created
        Contract C::KeywordArgs[
                   entitlement_group: Entitlements::Models::Group,
                 ] => C::Bool
        def create_team(entitlement_group:)
          begin
            team_name = entitlement_group.cn.downcase
            team_options = { name: team_name, repo_names: [], privacy: "closed" }

            begin
              entitlement_metadata = entitlement_group.metadata
              unless entitlement_metadata["parent_team_name"].nil?
                parent_team_data = graphql_team_data(entitlement_metadata["parent_team_name"])
                team_options[:parent_team_id] = parent_team_data[:team_id]
                Entitlements.logger.debug "create_team(team=#{team_name}) Parent team #{entitlement_metadata["parent_team_name"]} with id #{parent_team_data[:team_id]} found"
              end
            rescue Entitlements::Models::Group::NoMetadata
              Entitlements.logger.debug "create_team(team=#{team_name}) No metadata found"
            end

            Entitlements.logger.debug "create_team(team=#{team_name})"
            octokit.create_team(org, team_options)
            true
          rescue Octokit::UnprocessableEntity => e
            Entitlements.logger.debug "create_team(team=#{team_name}) ERROR - #{e.message}"
            false
          end
        end

        # Update a team
        #
        # team - Entitlements::Backend::GitHubTeam::Models::Team object
        #
        # Returns true if the team was updated
        Contract C::KeywordArgs[
                   team: Entitlements::Backend::GitHubTeam::Models::Team,
                   metadata: C::Or[Hash, nil]
                 ] => C::Bool
        def update_team(team:, metadata: {})
          begin
            Entitlements.logger.debug "update_team(team=#{team.team_name})"
            options = { name: team.team_name, repo_names: [], privacy: "closed", parent_team_id: metadata[:parent_team_id] }
            octokit.update_team(team.team_id, options)
            true
          rescue Octokit::UnprocessableEntity => e
            Entitlements.logger.debug "update_team(team=#{team.team_name}) ERROR - #{e.message}"
            false
          end
        end

        # Gets a team by name
        #
        # team - Entitlements::Backend::GitHubTeam::Models::Team object
        #
        # Returns true if the team was updated
        Contract C::KeywordArgs[
                   org_name: String,
                   team_name: String
                 ] => Sawyer::Resource
        def team_by_name(org_name:, team_name:)
          octokit.team_by_name(org_name, team_name)
        end

        private

        # GraphQL query for the members of a team identified by a slug. (For now
        # our GraphQL needs are simple so this is just a hard-coded query. In the
        # future if this gets more widely used, consider one of the graphql client
        # gems, such as https://github.com/github/graphql-client.)
        #
        # team_slug - Identifier of the team to retrieve.
        #
        # Returns a data structure with team data.
        Contract String => { members: C::ArrayOf[String], team_id: Integer, parent_team_name: C::Or[String, nil] }
        def graphql_team_data(team_slug)
          cursor = nil
          team_id = nil
          result = []
          sanity_counter = 0

          while sanity_counter < 100
            sanity_counter += 1
            first_str = cursor.nil? ? "first: #{max_graphql_results}" : "first: #{max_graphql_results}, after: \"#{cursor}\""
            query = "{
              organization(login: \"#{org}\") {
                team(slug: \"#{team_slug}\") {
                  databaseId
                  parentTeam {
                    slug
                  }
                  members(#{first_str}, membership: IMMEDIATE) {
                    edges {
                      node {
                        login
                      }
                      cursor
                    }
                  }
                }
              }
            }".gsub(/\n\s+/, "\n")

            response = graphql_http_post(query)
            unless response[:code] == 200
              Entitlements.logger.fatal "Abort due to GraphQL failure on #{query.inspect}"
              raise "GraphQL query failure"
            end

            team = response[:data].fetch("data").fetch("organization").fetch("team")
            if team.nil?
              raise TeamNotFound, "Requested team #{team_slug} does not exist in #{org}!"
            end

            team_id = team.fetch("databaseId")
            parent_team_name = team.dig("parentTeam", "slug")

            edges = team.fetch("members").fetch("edges")
            break unless edges.any?

            buffer = edges.map { |e| e.fetch("node").fetch("login").downcase }
            result.concat buffer

            cursor = edges.last.fetch("cursor")
            next if cursor && buffer.size == max_graphql_results
            break
          end

          { members: result, team_id: team_id, parent_team_name: parent_team_name }
        end

        # Ensure that the given team ID actually matches up to the team slug on GitHub. This is in place
        # because we are relying on something in graphql that we shouldn't be, until the attribute we need
        # is added as a first class citizen. Once that happens, this can be removed.
        #
        # team_id   - ID number of the team (Integer)
        # team_slug - Slug of the team (String)
        #
        # Returns nothing but raises if there's a mismatch.
        Contract Integer, String => nil
        def validate_team_id_and_slug!(team_id, team_slug)
          return if team_id == -999

          @validation_cache ||= {}
          @validation_cache[team_id] ||= begin
            Entitlements.logger.debug "validate_team_id_and_slug!(#{team_id}, #{team_slug.inspect})"
            team_data = octokit.team(team_id)
            team_data[:slug]
          end
          return if @validation_cache[team_id] == team_slug
          raise "validate_team_id_and_slug! mismatch: team_id=#{team_id} expected=#{team_slug.inspect} got=#{@validation_cache[team_id].inspect}"
        end

        # Add user to team.
        #
        # user - String with the GitHub username
        # team - Entitlements::Backend::GitHubTeam::Models::Team object for the team.
        #
        # Returns true if the user was added to the team, false if user was already on team.
        Contract C::KeywordArgs[
          user: String,
          team: Entitlements::Backend::GitHubTeam::Models::Team,
        ] => C::Bool
        def add_user_to_team(user:, team:)
          return false unless org_members.include?(user.downcase)
          Entitlements.logger.debug "#{identifier} add_user_to_team(user=#{user}, org=#{org}, team_id=#{team.team_id})"
          validate_team_id_and_slug!(team.team_id, team.team_name)
          result = octokit.add_team_membership(team.team_id, user)
          result[:state] == "active" || result[:state] == "pending"
        end

        # Remove user from team.
        #
        # user - String with the GitHub username
        # team - Entitlements::Backend::GitHubTeam::Models::Team object for the team.
        #
        # Returns true if the user was removed from the team, false if user was not on team.
        Contract C::KeywordArgs[
          user: String,
          team: Entitlements::Backend::GitHubTeam::Models::Team,
        ] => C::Bool
        def remove_user_from_team(user:, team:)
          return false unless org_members.include?(user.downcase)
          Entitlements.logger.debug "#{identifier} remove_user_from_team(user=#{user}, org=#{org}, team_id=#{team.team_id})"
          validate_team_id_and_slug!(team.team_id, team.team_name)
          octokit.remove_team_membership(team.team_id, user)
        end
      end
    end
  end
end
