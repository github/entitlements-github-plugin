# frozen_string_literal: true

require_relative "../../../spec_helper"

describe Entitlements::Backend::GitHubEnterpriseTeam::Service do
  let(:subject) do
    described_class.new(
      addr: "https://github.fake/api/v3",
      enterprise: "kittens inc",
      token: "GoPackGo",
      ou: "ou=teams,ou=GitHub,dc=github,dc=fake"
    )
  end
  let(:group) do
    Entitlements::Models::Group.new(
      dn: "cn=cuddly kittens,ou=teams,ou=GitHub,dc=github,dc=fake",
      members: Set.new(%w[octocat monalisa]),
      metadata: { "owner" => "octocat" }
    )
  end
  let(:team) do
    Entitlements::Backend::GitHubTeam::Models::Team.new(
      team_id: -1,
      team_name: "cuddly kittens",
      members: Set.new(%w[octocat]),
      ou: "ou=teams,ou=GitHub,dc=github,dc=fake",
      metadata: nil
    )
  end
  let(:headers) do
    {
      "Accept" => "application/vnd.github+json",
      "Authorization" => "Bearer GoPackGo",
      "X-GitHub-Api-Version" => "2026-03-10",
    }
  end
  let(:members_url) do
    "https://github.fake/api/v3/enterprises/kittens%20inc/teams/cuddly%20kittens/memberships?page=1&per_page=100"
  end

  describe "#read_team" do
    it "reads and normalizes enterprise team members" do
      stub_request(:get, members_url).with(headers:).to_return(
        status: 200,
        body: JSON.generate([{ "login" => "OctoCat" }, { "login" => "MonaLisa" }])
      )

      result = subject.read_team(group)

      expect(result.team_name).to eq("cuddly kittens")
      expect(result.team_id).to eq(-1)
      expect(result.member_strings).to eq(Set.new(%w[octocat monalisa]))
      expect(result.metadata).to eq("owner" => "octocat")
    end

    it "supports entitlement groups without metadata" do
      no_metadata = Entitlements::Models::Group.new(dn: group.dn, members: Set.new, metadata: nil)
      stub_request(:get, members_url).to_return(status: 200, body: JSON.generate([{ "login" => "OctoCat" }]))

      result = subject.read_team(no_metadata)
      expect(result.member_strings).to eq(Set.new(["octocat"]))
      expect { result.metadata }
        .to raise_error(Entitlements::Models::Group::NoMetadata)
    end

    it "paginates member listings" do
      first_page = Array.new(100) { |index| { "login" => "cat-#{index}" } }
      second_url = members_url.sub("page=1", "page=2")
      stub_request(:get, members_url).to_return(status: 200, body: JSON.generate(first_page))
      stub_request(:get, second_url).to_return(status: 200, body: JSON.generate([{ "login" => "last-cat" }]))

      expect(subject.read_team(group).member_strings.size).to eq(101)
    end

    it "raises a team not found error for a missing team" do
      stub_request(:get, members_url).to_return(status: 404, body: '{"message":"Not Found"}')

      expect { subject.read_team(group) }
        .to raise_error(described_class::TeamNotFound, /HTTP 404/)
    end

    it "propagates other API failures" do
      stub_request(:get, members_url).to_return(status: 403, body: '{"message":"Forbidden"}')

      expect { subject.read_team(group) }
        .to raise_error(described_class::APIError, /HTTP 403/)
    end
  end

  describe "#sync_team" do
    it "bulk adds and removes members" do
      desired = Entitlements::Models::Group.new(
        dn: group.dn,
        members: Set.new(%w[monalisa])
      )
      add_url = "https://github.fake/api/v3/enterprises/kittens%20inc/teams/cuddly%20kittens/memberships/add"
      remove_url = add_url.sub("/add", "/remove")
      stub_request(:post, add_url)
        .with(headers:, body: JSON.generate(usernames: ["monalisa"]))
        .to_return(status: 200, body: "[]")
      stub_request(:post, remove_url)
        .with(headers:, body: JSON.generate(usernames: ["octocat"]))
        .to_return(status: 200, body: "[]")
      expect(logger).to receive(:debug).with("sync_enterprise_team(cuddly kittens): Added 1, removed 1")

      expect(subject.sync_team(desired, team)).to eq(true)
    end

    it "does not call the API when membership is unchanged" do
      desired = Entitlements::Models::Group.new(dn: group.dn, members: Set.new(%w[OctoCat]))
      expect(logger).to receive(:debug).with("sync_enterprise_team(cuddly kittens): Added 0, removed 0")

      expect(subject.sync_team(desired, team)).to eq(false)
      expect(WebMock).not_to have_requested(:post, /memberships/)
    end
  end
end
