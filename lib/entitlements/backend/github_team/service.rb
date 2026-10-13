# frozen_string_literal: true

require_relative "models/team"
require_relative "../../service/github"

require "base64"
require "json"
require "set"

module Entitlements
  class Backend
    class GitHubTeam
      class Service < Entitlements::Service::GitHub
        include ::Contracts::Core
        include ::Contracts::Builtin
        C = ::Contracts

        class TeamNotFound < RuntimeError; end

        GRAPHQL_TEAM_BATCH_SIZE = 10
        MAX_GRAPHQL_TEAM_PAGES = 100

        # Constructor.
        #
        # addr             - Base URL a GitHub Enterprise API (leave undefined to use dotcom)
        # org              - String with organization name
        # token            - Access token for GitHub API
        # ou               - Base OU for fudged DNs
        # ignore_not_found - Boolean to ignore not found errors
        #
        # Returns nothing.
        Contract C::KeywordArgs[
          addr: C::Maybe[String],
          org: String,
          token: String,
          ou: String,
          ignore_not_found: C::Maybe[C::Bool],
        ] => C::Any
        def initialize(org:, token:, ou:, addr: nil, ignore_not_found: false)
          super
          Entitlements.cache[:github_team_members] ||= {}
          Entitlements.cache[:github_team_members][org_signature] ||= {}
          @team_cache = Entitlements.cache[:github_team_members][org_signature]
        end

        # Read a single team identified by its slug and return a team object.
        # This is aware of the predictive cache and will use it if appropriate.
        #
        # entitlement_group - Entitlements::Models::Group representing the entitlement being worked on
        #
        # Returns a Entitlements::Backend::GitHubTeam::Models::Team or nil if the team does not exist
        Contract Entitlements::Models::Group => C::Maybe[Entitlements::Backend::GitHubTeam::Models::Team]
        def read_team(entitlement_group)
          read_teams([entitlement_group]).fetch(entitlement_group.cn.downcase)
        end

        # Read multiple teams, using predictive state where valid and bounded GraphQL
        # batches for the teams that require authoritative state.
        #
        # entitlement_groups - Array of desired Entitlements::Models::Group objects.
        #
        # Returns a Hash keyed by lower-case team slug.
        Contract C::ArrayOf[Entitlements::Models::Group] => C::HashOf[String => C::Maybe[Entitlements::Backend::GitHubTeam::Models::Team]]
        def read_teams(entitlement_groups)
          result = {}
          authoritative_groups = []

          entitlement_groups.each do |entitlement_group|
            team_identifier = entitlement_group.cn.downcase
            if @team_cache.key?(team_identifier)
              result[team_identifier] = @team_cache.fetch(team_identifier)[:value]
              next
            end

            predictive_team = team_from_predictive_cache(entitlement_group)
            if predictive_team
              @team_cache[team_identifier] = { cache: true, value: predictive_team }
              result[team_identifier] = predictive_team
            else
              Entitlements.logger.debug "Loading GitHub team #{identifier}:#{org}/#{team_identifier}"
              authoritative_groups << entitlement_group
            end
          end

          unless authoritative_groups.empty?
            team_data = if authoritative_groups.one?
                          team_identifier = authoritative_groups.first.cn.downcase
                          begin
                            { team_identifier => graphql_team_data(team_identifier) }
                          rescue TeamNotFound
                            { team_identifier => nil }
                          end
                        else
                          graphql_team_data_batch(authoritative_groups.map { |group| group.cn.downcase })
                        end

            authoritative_groups.each do |entitlement_group|
              team_identifier = entitlement_group.cn.downcase
              data = team_data.fetch(team_identifier)
              team = data && team_from_graphql_data(entitlement_group, data)
              unless team
                Entitlements.logger.warn "Team #{team_identifier} does not exist in this GitHub.com organization. If applied, the team will be created."
              end
              @team_cache[team_identifier] = { cache: false, value: team }
              result[team_identifier] = team
            end
          end

          result
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
          @team_cache[team_identifier] && @team_cache[team_identifier][:cache] ? true : false
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

          desired_team_members = Set.new(desired_state.member_strings.map { |u| u.downcase })
          current_team_members = Set.new(current_state.member_strings.map { |u| u.downcase })

          added_members = desired_team_members - current_team_members
          removed_members = current_team_members - desired_team_members

          added_members.select! { |username| add_user_to_team(user: username, team: current_state) }
          removed_members.select! { |username| remove_user_from_team(user: username, team: current_state) }

          added_maintainers = Set.new
          removed_maintainers = Set.new
          unless desired_metadata["team_maintainers"] == current_metadata["team_maintainers"]
            if desired_metadata["team_maintainers"].nil?
              # We will not delete ALL maintainers from a team and leave it without maintainers.
              Entitlements.logger.debug "sync_team(#{current_state.team_name}=#{current_state.team_id}): IGNORING GitHub Team Maintainer DELETE"
            else
              desired_maintainers_str = desired_metadata["team_maintainers"] # not nil, we tested that above
              desired_maintainers = Set.new(desired_maintainers_str.split(",").map { |u| u.strip.downcase })
              unless desired_maintainers.subset?(desired_team_members)
                maintainer_not_member = desired_maintainers - desired_team_members
                Entitlements.logger.warn "sync_team(#{current_state.team_name}=#{current_state.team_id}): Maintainers must be a subset of team members. Desired maintainers: #{maintainer_not_member.to_a} are not members. Ignoring."
                desired_maintainers = desired_maintainers.intersection(desired_team_members)
              end

              current_maintainers_str = current_metadata["team_maintainers"]
              current_maintainers = Set.new(
                current_maintainers_str.nil? ? [] : current_maintainers_str.split(",").map { |u| u.strip.downcase }
              )
              # We ignore any current maintainer who is not a member of the team according to the team spec
              # This avoids messing with teams who have been manually modified to add a maintainer
              current_maintainers = current_maintainers.intersection(desired_team_members)
              added_maintainers = desired_maintainers - current_maintainers
              removed_maintainers = current_maintainers - desired_maintainers
              if added_maintainers.empty? && removed_maintainers.empty?
                Entitlements.logger.debug "sync_team(#{current_state.team_name}=#{current_state.team_id}): Textual change but no semantic change in maintainers. It is remains: #{current_maintainers.to_a}."
              else
                Entitlements.logger.debug "sync_team(#{current_state.team_name}=#{current_state.team_id}): Maintainer members change found - From #{current_maintainers.to_a} to #{desired_maintainers.to_a}"
                added_maintainers.select! do |username|
                  add_user_to_team(user: username, team: current_state, role: "maintainer")
                end

                ## We only touch previous maintainers who are actually still going to be members of the team
                removed_maintainers = removed_maintainers.intersection(desired_team_members)
                ## Downgrade membership to default (role: "member")
                removed_maintainers.select! do |username|
                  add_user_to_team(user: username, team: current_state, role: "member")
                end
              end
            end
          end

          Entitlements.logger.debug "sync_team(#{current_state.team_name}=#{current_state.team_id}): Added #{added_members.count}, removed #{removed_members.count}"
          added_members.any? || removed_members.any? || added_maintainers.any? || removed_maintainers.any? || changed_parent_team
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
          team_name = entitlement_group.cn.downcase
          team_options = { name: team_name, repo_names: [], privacy: "closed" }

          begin
            entitlement_metadata = entitlement_group.metadata
            unless entitlement_metadata["parent_team_name"].nil?

              begin
                parent_team_data = graphql_team_data(entitlement_metadata["parent_team_name"])
                team_options[:parent_team_id] = parent_team_data[:team_id]
              rescue TeamNotFound
                # if the parent team does not exist, create it (think `mkdir -p` logic here)
                result = Retryable.with_context(:default, not: [Octokit::UnprocessableEntity]) do
                  octokit.create_team(
                    org,
                    { name: entitlement_metadata["parent_team_name"], repo_names: [], privacy: "closed" }
                  )
                end

                Entitlements.logger.debug "created parent team #{entitlement_metadata["parent_team_name"]} with id #{result[:id]}"

                team_options[:parent_team_id] = result[:id]
              end

              Entitlements.logger.debug "create_team(team=#{team_name}) Parent team #{entitlement_metadata["parent_team_name"]} with id #{team_options[:parent_team_id]} found"
            end
          rescue Entitlements::Models::Group::NoMetadata
            Entitlements.logger.debug "create_team(team=#{team_name}) No metadata found"
          end

          Entitlements.logger.debug "create_team(team=#{team_name})"

          result = Retryable.with_context(:default, not: [Octokit::UnprocessableEntity]) do
            octokit.create_team(org, team_options)
          end

          Entitlements.logger.debug "created team #{team_name} with id #{result[:id]}"
          true
        rescue Octokit::UnprocessableEntity => e
          Entitlements.logger.debug "create_team(team=#{team_name}) ERROR - #{e.message}"
          false
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
          Entitlements.logger.debug "update_team(team=#{team.team_name})"
          options = { name: team.team_name, repo_names: [], privacy: "closed",
                      parent_team_id: metadata[:parent_team_id] }
          Retryable.with_context(:default, not: [Octokit::UnprocessableEntity]) do
            octokit.update_team(team.team_id, options)
          end

          true
        rescue Octokit::UnprocessableEntity => e
          Entitlements.logger.debug "update_team(team=#{team.team_name}) ERROR - #{e.message}"
          false
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
          Retryable.with_context(:default) do
            octokit.team_by_name(org_name, team_name)
          end
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
        Contract String => { members: C::ArrayOf[String], team_id: Integer, parent_team_name: C::Or[String, nil],
                             roles: C::HashOf[String => String] }
        def graphql_team_data(team_slug)
          result = graphql_team_data_batch([team_slug]).fetch(team_slug)
          raise TeamNotFound, "Requested team #{team_slug} does not exist in #{org}!" if result.nil?

          result
        end

        def graphql_team_data_batch(team_slugs)
          states = team_slugs.to_h do |team_slug|
            [team_slug, { members: [], roles: {}, team_id: nil, parent_team_name: nil, cursor: nil, pages: 0 }]
          end
          pending_team_slugs = team_slugs

          until pending_team_slugs.empty?
            next_pending_team_slugs = []

            pending_team_slugs.each_slice(graphql_team_batch_size) do |batch|
              alias_to_team = batch.each_with_index.to_h { |team_slug, index| ["team#{index}", team_slug] }
              query = graphql_team_batch_query(alias_to_team, states)
              response = graphql_http_post(query)
              unless response[:code] == 200
                Entitlements.logger.fatal "Abort due to GraphQL failure on #{query.inspect}"
                raise "GraphQL query failure"
              end

              response_data = response[:data].fetch("data")
              organization = response_data.fetch("organization")
              raise "GraphQL response missing organization #{org}" if organization.nil?

              log_graphql_rate_limit(response_data["rateLimit"])

              alias_to_team.each do |team_alias, team_slug|
                state = states.fetch(team_slug)
                team = organization.fetch(team_alias)
                if team.nil?
                  raise "GitHub team #{team_slug} disappeared during pagination" if state[:pages].positive?

                  states[team_slug] = nil
                  next
                end

                state[:pages] += 1
                team_id = team.fetch("databaseId")
                if state[:team_id] && state[:team_id] != team_id
                  raise "GitHub team #{team_slug} changed database ID during pagination"
                end
                state[:team_id] = team_id
                state[:parent_team_name] = team.dig("parentTeam", "slug")

                edges = team.fetch("members").fetch("edges")
                edges.each do |edge|
                  username = edge.fetch("node").fetch("login").downcase
                  state[:members] << username
                  state[:roles][username] = edge.fetch("role").downcase
                end

                next unless edges.size == max_graphql_results

                cursor = edges.last.fetch("cursor")
                raise "GitHub team #{team_slug} returned a full page without a cursor" if cursor.nil?
                if state[:pages] >= MAX_GRAPHQL_TEAM_PAGES
                  raise "GitHub team #{team_slug} exceeded the #{MAX_GRAPHQL_TEAM_PAGES}-page GraphQL limit"
                end

                state[:cursor] = cursor
                next_pending_team_slugs << team_slug
              end
            end

            pending_team_slugs = next_pending_team_slugs
          end

          states.transform_values do |state|
            next if state.nil?

            state.slice(:members, :roles, :team_id, :parent_team_name)
          end
        end

        def graphql_team_batch_query(alias_to_team, states)
          team_fields = alias_to_team.map do |team_alias, team_slug|
            cursor = states.fetch(team_slug)[:cursor]
            pagination = "first: #{max_graphql_results}"
            pagination += ", after: #{graphql_string_literal(cursor)}" if cursor
            "#{team_alias}: team(slug: #{graphql_string_literal(team_slug)}) {
              databaseId
              parentTeam {
                slug
              }
              members(#{pagination}, membership: IMMEDIATE) {
                edges {
                  node {
                    login
                  }
                  role
                  cursor
                }
              }
            }"
          end.join("\n")

          "query {
            rateLimit {
              cost
              remaining
              resetAt
            }
            organization(login: #{graphql_string_literal(org)}) {
              #{team_fields}
            }
          }".gsub(/\n\s+/, "\n")
        end

        Contract String => String
        def graphql_string_literal(value)
          JSON.generate(value)
        end

        def graphql_team_batch_size
          GRAPHQL_TEAM_BATCH_SIZE
        end

        def log_graphql_rate_limit(rate_limit)
          return if rate_limit.nil?

          Entitlements.logger.debug(
            "GitHub GraphQL team batch cost=#{rate_limit['cost']} remaining=#{rate_limit['remaining']} reset_at=#{rate_limit['resetAt']}"
          )
        end

        def team_from_predictive_cache(entitlement_group)
          team_identifier = entitlement_group.cn.downcase
          dn = "cn=#{team_identifier},#{ou}"
          cached_members = Entitlements::Data::Groups::Cached.members(dn)
          return if cached_members.nil?

          Entitlements.logger.debug "Loading GitHub team #{identifier}:#{org}/#{team_identifier} from cache"
          cached_metadata = Entitlements::Data::Groups::Cached.metadata(dn)
          entitlement_metadata = metadata_from_entitlement(entitlement_group)
          team_metadata = if cached_metadata.nil?
                            entitlement_metadata
                          elsif entitlement_metadata.nil?
                            cached_metadata
                          else
                            entitlement_metadata.merge(cached_metadata)
                          end

          Entitlements::Backend::GitHubTeam::Models::Team.new(
            team_id: -1,
            team_name: team_identifier,
            members: cached_members,
            ou:,
            metadata: team_metadata
          )
        end

        def team_from_graphql_data(entitlement_group, teamdata)
          team_identifier = entitlement_group.cn.downcase
          entitlement_metadata = metadata_from_entitlement(entitlement_group)
          parent_team_name = teamdata[:parent_team_name]
          team_metadata = if parent_team_name.nil?
                            entitlement_metadata
                          else
                            (entitlement_metadata || {}).merge("parent_team_name" => parent_team_name)
                          end

          maintainers = teamdata[:members].select { |username| teamdata[:roles][username] == "maintainer" }
          team_metadata = (team_metadata || {}).merge("team_maintainers" => maintainers.any? ? maintainers.join(",") : nil)

          Entitlements::Backend::GitHubTeam::Models::Team.new(
            team_id: teamdata[:team_id],
            team_name: team_identifier,
            members: Set.new(teamdata[:members]),
            ou:,
            metadata: team_metadata
          )
        end

        def metadata_from_entitlement(entitlement_group)
          entitlement_group.metadata
        rescue Entitlements::Models::Group::NoMetadata
          nil
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
            team_data = Retryable.with_context(:default) do
              octokit.team(team_id)
            end

            team_data[:slug]
          end
          return if @validation_cache[team_id] == team_slug

          raise "validate_team_id_and_slug! mismatch: team_id=#{team_id} expected=#{team_slug.inspect} got=#{@validation_cache[team_id].inspect}"
        end

        # Add user to team.
        #
        # user - String with the GitHub username
        # team - Entitlements::Backend::GitHubTeam::Models::Team object for the team.
        # role - optional (default: "member") String with the role to assign to the user: either "member" or "maintainer"
        #
        # Returns true if the user was added to the team or role changed; false if user was already on team with same role
        Contract C::KeywordArgs[
          user: String,
          team: Entitlements::Backend::GitHubTeam::Models::Team,
          role: C::Optional[String]
        ] => C::Bool
        def add_user_to_team(user:, team:, role: "member")
          return false unless org_members.include?(user.downcase)
          unless ["member", "maintainer"].include?(role)
            # :nocov:
            raise "add_user_to_team role mismatch: team_id=#{team.team_id} user=#{user} expected role=maintainer/member got=#{role}"
          end

          Entitlements.logger.debug "#{identifier} add_user_to_team(user=#{user}, org=#{org}, team_id=#{team.team_id}, role=#{role})"
          validate_team_id_and_slug!(team.team_id, team.team_name)

          begin
            result = Retryable.with_context(:default, not: [Octokit::UnprocessableEntity, Octokit::NotFound]) do
              octokit.add_team_membership(team.team_id, user, role:)
            end

            result[:state] == "active" || result[:state] == "pending"
          rescue Octokit::UnprocessableEntity => e
            Entitlements.logger.warn "User #{user} not found in organization #{org}, ignoring."
            false
          rescue Octokit::NotFound => e
            raise e unless ignore_not_found

            Entitlements.logger.warn "User #{user} not found in GitHub instance #{identifier}, ignoring."
            false
          end
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

          Retryable.with_context(:default) do
            octokit.remove_team_membership(team.team_id, user)
          end
        end
      end
    end
  end
end
