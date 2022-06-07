# frozen_string_literal: true

module Entitlements
  class Backend
    class GitHubTeam
      class Models
        class Team < Entitlements::Models::Group
          include ::Contracts::Core
          C = ::Contracts

          attr_reader :team_id, :team_name, :team_dn

          # Constructor.
          #
          # team_id   - Integer with the team ID
          # team_name - String with the team name
          # members   - Set of String with member UID
          # ou        - A String with the base OU
          Contract C::KeywordArgs[
            team_id: Integer,
            team_name: String,
            members: C::SetOf[String],
            ou: String,
            metadata: C::Or[C::HashOf[String => C::Any], nil]
          ] => C::Any
          def initialize(team_id:, team_name:, members:, ou:, metadata:)
            @team_id = team_id
            @team_name = team_name.downcase
            @team_dn = ["cn=#{team_name.downcase}", ou].join(",")
            super(dn: @team_dn, members: Set.new(members.map { |m| m.downcase }), metadata: metadata)
          end
        end
      end
    end
  end
end
