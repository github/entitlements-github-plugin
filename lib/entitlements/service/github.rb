# frozen_string_literal: true

require_relative "../config/retry"

require "net/http"
require "octokit"
require "uri"

module Entitlements
  class Service
    class GitHub
      include ::Contracts::Core
      C = ::Contracts

      # This is a limitation of the GitHub API
      MAX_GRAPHQL_RESULTS = 100

      # Retries to smooth over transient network blips
      MAX_GRAPHQL_RETRIES = 3
      WAIT_BETWEEN_GRAPHQL_RETRIES = 1

      attr_reader :addr, :org, :token, :ou, :ignore_not_found

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
      def initialize(addr: nil, org:, token:, ou:, ignore_not_found: false)
        # init the retry module
        Retry.setup!

        # Save some parameters for the connection but don't actually connect yet.
        @addr = addr
        @org = org
        @token = token
        @ou = ou
        @ignore_not_found = ignore_not_found

        # This is a global cache across all invocations of this object. GitHub membership
        # need to be obtained only one time per organization, but might be used multiple times.
        Entitlements.cache[:github_pending_members] ||= {}
        Entitlements.cache[:github_org_members] ||= {}
      end

      # Return the identifier, either the address specified or otherwise "github.com".
      #
      # Takes no arguments.
      #
      # Returns the address.
      Contract C::None => String
      def identifier
        @identifier ||= begin
          if addr.nil?
            "github.com"
          else
            u = URI(addr)
            u.host
          end
        end
      end

      # Read the members of an organization and return a Hash of users with their role.
      # This method does not need parameters because the underlying service already
      # has the organization available in an `org` method.
      #
      # Takes no parameters.
      #
      # Returns Hash of { "username" => "role" }.
      Contract C::None => C::HashOf[String => String]
      def org_members
        Entitlements.cache[:github_org_members][org_signature] ||= begin
          roles = Entitlements::Backend::GitHubOrg::ORGANIZATION_ROLES.invert

          # Some basic stats are helpful for debugging
          data, cache = members_and_roles_from_graphql_or_cache
          result = data.map { |username, role| [username, roles.fetch(role)] }.to_h
          admin_count = result.count { |_, role| role == "admin" }
          member_count = result.count { |_, role| role == "member" }
          Entitlements.logger.debug "Currently #{org} has #{admin_count} admin(s) and #{member_count} member(s)"

          { cache:, value: result }
        end

        Entitlements.cache[:github_org_members][org_signature][:value]
      end

      # Returns true if the github instance is an enterprise server instance
      Contract C::None => C::Bool
      def enterprise?
        meta = Retryable.with_context(:default) do
          octokit.github_meta
        end

        meta.key? :installed_version
      end

      # Read the members of an organization who are in a "pending" role. These users should
      # not be re-invited or updated unless and until they have accepted the invitation.
      #
      # Takes no parameters.
      #
      # Returns Set of usernames.
      Contract C::None => C::SetOf[String]
      def pending_members
        Entitlements.cache[:github_pending_members][org_signature] ||= begin
          # ghes does not support org invites
          return Set.new if enterprise?
          pm = pending_members_from_graphql
          Entitlements.logger.debug "Currently #{org} has #{pm.size} pending member(s)"
          pm
        end
      end

      # Determine whether the most recent entry came from the predictive cache or an actual
      # call to the API.
      #
      # Takes no arguments.
      #
      # Returns true if it came from the cache, or false if it came from the API.
      Contract C::None => C::Bool
      def org_members_from_predictive_cache?
        org_members # Force this to be read if for some reason it has not been yet.
        Entitlements.cache[:github_org_members][org_signature][:cache] || false
      end

      # Invalidate the predictive cache for organization members, and if the prior knowledge
      # of that role was from the cache, re-read from the actual data source.
      #
      # Takes no arguments.
      #
      # Returns nothing.
      Contract C::None => nil
      def invalidate_org_members_predictive_cache
        # If the entry was not from the predictive cache in the first place, just return.
        # This really should not get called if that's the case, but regardless, we don't
        # want to pointlessly hit the API twice.
        return unless org_members_from_predictive_cache?

        # The entry did come from the predictive cache. Invalidate the entry, clear local
        # caches, and re-read the data from the API.
        Entitlements.logger.debug "Invalidating cache entries for cn=(admin|member),#{ou}"
        Entitlements::Data::Groups::Cached.invalidate("cn=admin,#{ou}")
        Entitlements::Data::Groups::Cached.invalidate("cn=member,#{ou}")
        Entitlements.cache[:github_org_members].delete(org_signature)
        org_members
        nil
      end

      private

      # The octokit object is initialized the first time it's called.
      #
      # Takes no arguments.
      #
      # Returns an Octokit client object.
      Contract C::None => Octokit::Client
      def octokit
        @octokit ||= begin
          client = Octokit::Client.new(access_token: token)
          client.api_endpoint = addr if addr
          client.auto_paginate = true
          client.per_page = 100
          Entitlements.logger.debug "Setting up GitHub API connection to #{client.api_endpoint}"
          client
        end
      end

      # Get data from the predictive updates cache if it's available and valid, or else get it
      # from GraphQL API. This is a shim between readers and `members_and_roles_from_graphql`.
      #
      # Takes no parameters.
      #
      # Returns Hash of { "username" => "ROLE" } where "ROLE" is from GraphQL Enum.
      Contract C::None => [C::HashOf[String => String], C::Bool]
      def members_and_roles_from_graphql_or_cache
        admin_from_cache = Entitlements::Data::Groups::Cached.members("cn=admin,#{ou}")
        member_from_cache = Entitlements::Data::Groups::Cached.members("cn=member,#{ou}")

        # If we do not have *both* admins and members, we need to call the API
        return [members_and_roles_from_rest, false] unless admin_from_cache && member_from_cache

        # Convert the Sets of strings into the expected hash structure.
        Entitlements.logger.debug "Loading organization members and roles for #{org} from cache"
        result = admin_from_cache.map { |uid| [uid, "ADMIN"] }.to_h
        result.merge! member_from_cache.map { |uid| [uid, "MEMBER"] }.to_h
        [result, true]
      end

      # Query GraphQL API to get a list of members and their roles.
      #
      # Takes no parameters.
      #
      # Returns Hash of { "username" => "ROLE" } where "ROLE" is from GraphQL Enum.
      Contract C::None => C::HashOf[String => String]
      def members_and_roles_from_graphql
        Entitlements.logger.debug "Loading organization members and roles for #{org}"

        cursor = nil
        result = {}
        sanity_counter = 0

        while sanity_counter < 100
          sanity_counter += 1
          first_str = cursor.nil? ? "first: #{max_graphql_results}" : "first: #{max_graphql_results}, after: \"#{cursor}\""
          query = "{
            organization(login: \"#{org}\") {
              membersWithRole(#{first_str}) {
                edges {
                  node {
                    login
                  }
                  role
                }
                pageInfo { endCursor }
              }
            }
          }".gsub(/\n\s+/, "\n")

          response = graphql_http_post(query)
          unless response[:code] == 200
            Entitlements.logger.fatal "Abort due to GraphQL failure on #{query.inspect}"
            raise "GraphQL query failure"
          end

          membersWithRole = response[:data].fetch("data").fetch("organization").fetch("membersWithRole")
          edges = membersWithRole.fetch("edges")
          break unless edges.any?

          edges.each do |edge|
            result[edge.fetch("node").fetch("login").downcase] = edge.fetch("role")
          end

          cursor = membersWithRole.fetch("pageInfo").fetch("endCursor")
          next if cursor && edges.size == max_graphql_results
          break
        end

        result
      end

      # Returns Hash of { "username" => "ROLE" } where "ROLE" is ADMIN or MEMBER
      Contract C::None => C::HashOf[String => String]
      def members_and_roles_from_rest
        Entitlements.logger.debug "Loading organization members and roles for #{org}"
        result = {}

        # fetch all the admin members from the org
        admin_members = Retryable.with_context(:default) do
          octokit.organization_members(org, { role: "admin" })
        end

        # fetch all the regular members from the org
        regular_members = Retryable.with_context(:default) do
          octokit.organization_members(org, { role: "member" })
        end

        admin_members.each do |member|
          result[member[:login].downcase] = "ADMIN"
        end

        regular_members.each do |member|
          result[member[:login].downcase] = "MEMBER"
        end

        result
      end

      # Query GraphQL API to get a list of pending members for the organization.
      #
      # Takes no parameters.
      #
      # Returns Set of usernames.
      def pending_members_from_graphql
        # Since pending members is really a state and not an entitlement, this code does
        # not attempt to use a predictive cache. When this is invoked, it contacts the API.

        cursor = nil
        result = Set.new
        sanity_counter = 0

        while sanity_counter < 100
          sanity_counter += 1
          first_str = cursor.nil? ? "first: #{max_graphql_results}" : "first: #{max_graphql_results}, after: \"#{cursor}\""
          query = "{
            organization(login: \"#{org}\") {
              pendingMembers(#{first_str}) {
                edges {
                  node {
                    login
                  }
                }
                pageInfo { endCursor }
              }
            }
          }".gsub(/\n\s+/, "\n")

          response = graphql_http_post(query)
          unless response[:code] == 200
            Entitlements.logger.fatal "Abort due to GraphQL failure on #{query.inspect}"
            raise "GraphQL query failure"
          end

          pendingMembers = response[:data].fetch("data").fetch("organization").fetch("pendingMembers")
          edges = pendingMembers.fetch("edges")
          break unless edges.any?

          edges.each do |edge|
            result.add(edge.fetch("node").fetch("login").downcase)
          end

          cursor = pendingMembers.fetch("pageInfo").fetch("endCursor")
          next if cursor && edges.size == max_graphql_results
          break
        end

        result
      end

      # Helper method: Do the HTTP POST to the GitHub API for GraphQL. This has a retry which is
      # intended to avoid a failure due to a network blip.
      #
      # query - String with the data to be posted.
      #
      # Returns { code: <Integer>, data: <response data structure> }
      Contract String => { code: Integer, data: C::Or[nil, Hash] }
      def graphql_http_post(query)
        1.upto(MAX_GRAPHQL_RETRIES) do |try_number|
          result = graphql_http_post_real(query)
          if result[:code] < 500
            return result
          elsif try_number >= MAX_GRAPHQL_RETRIES
            Entitlements.logger.error "Query still failing after #{MAX_GRAPHQL_RETRIES} tries. Giving up."
            return result
          else
            Entitlements.logger.warn "GraphQL failed on try #{try_number} of #{MAX_GRAPHQL_RETRIES}. Will retry."
            sleep WAIT_BETWEEN_GRAPHQL_RETRIES * (2**(try_number - 1))
          end
        end
      end

      # Helper method: Do the HTTP POST to the GitHub API for GraphQL.
      #
      # query - String with the data to be posted.
      #
      # Returns { code: <Integer>, data: <response data structure> }
      Contract String => { code: Integer, data: C::Or[nil, Hash] }
      def graphql_http_post_real(query)
        uri = URI.parse(File.join(octokit.api_endpoint, "graphql"))
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"

        request = Net::HTTP::Post.new(uri)
        request.add_field("Authorization", "bearer #{token}")
        request.add_field("Content-Type", "application/json")
        request.body = JSON.generate("query" => query)

        begin
          response = http.request(request)

          if response.code != "200"
            Entitlements.logger.error "Got HTTP #{response.code} POSTing to #{uri}"
            Entitlements.logger.error response.body
            return { code: response.code.to_i, data: { "body" => response.body } }
          end

          begin
            data = JSON.parse(response.body)
            if data.key?("errors")
              Entitlements.logger.error "Errors reported: #{data['errors'].inspect}"
              return { code: 500, data: }
            end
            { code: response.code.to_i, data: }
          rescue JSON::ParserError => e
            Entitlements.logger.error "#{e.class} #{e.message}: #{response.body.inspect}"
            { code: 500, data: { "body" => response.body } }
          end
        rescue => e
          Entitlements.logger.error "Caught #{e.class} POSTing to #{uri}: #{e.message}"
          { code: 500, data: nil }
        end
      end

      # Create a unique signature for this GitHub instance to identify it in a global cache.
      #
      # Takes no arguments.
      #
      # Returns a String.
      Contract C::None => String
      def org_signature
        [addr || "", org].join("|")
      end

      # Get the maximum GraphQL results. This is a method that just returns the constant
      # but this way it can be overridden in tests.
      #
      # Takes no arguments.
      #
      # Returns an Integer.
      # :nocov:
      Contract C::None => Integer
      def max_graphql_results
        MAX_GRAPHQL_RESULTS
      end
      # :nocov:
    end
  end
end
