# frozen_string_literal: true

require_relative "../github_team/models/team"
require_relative "../../service/github"

require "cgi"
require "json"
require "net/http"
require "set"
require "uri"

module Entitlements
  class Backend
    class GitHubEnterpriseTeam
      class Service < Entitlements::Service::GitHub
        include ::Contracts::Core
        C = ::Contracts

        API_VERSION = "2026-03-10"
        PER_PAGE = 100

        class APIError < RuntimeError
          attr_reader :status

          def initialize(status, body)
            @status = status
            super("GitHub enterprise team API returned HTTP #{status}: #{body}")
          end
        end

        class TeamNotFound < APIError; end

        attr_reader :enterprise

        Contract C::KeywordArgs[
          addr: C::Maybe[String],
          enterprise: String,
          token: String,
          ou: String,
        ] => C::Any
        def initialize(enterprise:, token:, ou:, addr: nil)
          @enterprise = enterprise
          super(addr:, org: enterprise, token:, ou:)
        end

        Contract Entitlements::Models::Group => Entitlements::Backend::GitHubTeam::Models::Team
        def read_team(entitlement_group)
          team_name = entitlement_group.cn.downcase
          members = list_members(team_name)
          metadata = entitlement_group.metadata
          Entitlements::Backend::GitHubTeam::Models::Team.new(
            team_id: -1,
            team_name:,
            members: Set.new(members.map { |member| member.fetch("login").downcase }),
            ou:,
            metadata:
          )
        rescue Entitlements::Models::Group::NoMetadata
          Entitlements::Backend::GitHubTeam::Models::Team.new(
            team_id: -1,
            team_name:,
            members: Set.new(members.map { |member| member.fetch("login").downcase }),
            ou:,
            metadata: nil
          )
        end

        Contract Entitlements::Models::Group, Entitlements::Backend::GitHubTeam::Models::Team => C::Bool
        def sync_team(desired_state, current_state)
          desired_members = Set.new(desired_state.member_strings.map(&:downcase))
          current_members = Set.new(current_state.member_strings.map(&:downcase))
          added_members = desired_members - current_members
          removed_members = current_members - desired_members

          bulk_update(current_state.team_name, "add", added_members) if added_members.any?
          bulk_update(current_state.team_name, "remove", removed_members) if removed_members.any?

          Entitlements.logger.debug(
            "sync_enterprise_team(#{current_state.team_name}): Added #{added_members.count}, removed #{removed_members.count}"
          )
          added_members.any? || removed_members.any?
        end

        private

        def list_members(team_name)
          members = []
          page = 1

          loop do
            path = "#{team_path(team_name)}/memberships?per_page=#{PER_PAGE}&page=#{page}"
            page_members = request(Net::HTTP::Get, path)
            members.concat(page_members)
            break if page_members.length < PER_PAGE

            page += 1
          end

          members
        rescue APIError => e
          raise TeamNotFound.new(e.status, e.message) if e.status == 404

          raise
        end

        def bulk_update(team_name, operation, usernames)
          request(
            Net::HTTP::Post,
            "#{team_path(team_name)}/memberships/#{operation}",
            body: { usernames: usernames.to_a }
          )
        end

        def team_path(team_name)
          "/enterprises/#{escape(enterprise)}/teams/#{escape(team_name)}"
        end

        def escape(value)
          CGI.escape(value).gsub("+", "%20")
        end

        def request(request_class, path, body: nil)
          uri = URI.parse("#{(addr || "https://api.github.com").sub(%r{/+\z}, "")}#{path}")
          request = request_class.new(uri)
          request["Accept"] = "application/vnd.github+json"
          request["Authorization"] = "Bearer #{token}"
          request["X-GitHub-Api-Version"] = API_VERSION
          if body
            request["Content-Type"] = "application/json"
            request.body = JSON.generate(body)
          end

          response = Retryable.with_context(:default) do
            Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }
          end
          raise APIError.new(response.code.to_i, response.body) unless response.is_a?(Net::HTTPSuccess)

          return nil if response.body.nil? || response.body.empty?

          JSON.parse(response.body)
        end
      end
    end
  end
end
