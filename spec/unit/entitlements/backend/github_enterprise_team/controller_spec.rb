# frozen_string_literal: true

require_relative "../../../spec_helper"

describe Entitlements::Backend::GitHubEnterpriseTeam::Controller do
  let(:config) do
    {
      "base" => "ou=teams,ou=GitHub,dc=github,dc=fake",
      "enterprise" => "kittensinc",
      "token" => "GoPackGo",
      "type" => "github_enterprise_team",
    }
  end
  let(:subject) { described_class.new("enterprise-teams", config) }
  let(:provider) { instance_double(Entitlements::Backend::GitHubEnterpriseTeam::Provider) }
  let(:group) do
    Entitlements::Models::Group.new(
      dn: "cn=cats,ou=teams,ou=GitHub,dc=github,dc=fake",
      members: Set.new(%w[octocat])
    )
  end
  let(:team) do
    Entitlements::Backend::GitHubTeam::Models::Team.new(
      team_id: -1,
      team_name: "cats",
      members: Set.new,
      ou: config.fetch("base"),
      metadata: nil
    )
  end

  before do
    subject.instance_variable_set("@provider", provider)
    allow(Entitlements::Data::Groups::Calculated).to receive(:read_all)
      .with("enterprise-teams", hash_including("enterprise" => "kittensinc"))
      .and_return(Set.new(["cats"]))
    allow(Entitlements::Data::Groups::Calculated).to receive(:read).with("cats").and_return(group)
  end

  it "has the standard team controller priority" do
    expect(described_class.priority).to eq(40)
  end

  it "prefetches configured teams" do
    expect(provider).to receive(:read).with(group).and_return(team)

    subject.prefetch
  end

  it "returns actions for changed teams" do
    allow(provider).to receive(:diff).with(group).and_return(added: Set.new(["octocat"]), removed: Set.new)
    allow(provider).to receive(:read).with(group).and_return(team)
    allow(subject).to receive(:print_differences)

    result = subject.calculate

    expect(result.length).to eq(1)
    expect(result.first.existing).to eq(team)
    expect(result.first.updated).to eq(group)
  end

  it "skips unchanged teams" do
    allow(provider).to receive(:diff).with(group).and_return(added: Set.new, removed: Set.new)
    expect(logger).to receive(:debug).with("UNCHANGED: No GitHub enterprise team changes for enterprise-teams:cats")
    allow(subject).to receive(:print_differences)

    expect(subject.calculate).to eq([])
  end

  it "applies membership updates" do
    action = Entitlements::Models::Action.new("cats", team, group, "enterprise-teams")
    expect(provider).to receive(:commit).with(group).and_return(true)
    expect(logger).to receive(:debug).with("APPLY: Updating GitHub enterprise team cats")

    subject.apply(action)
  end

  it "warns when no membership update is needed" do
    action = Entitlements::Models::Action.new("cats", team, group, "enterprise-teams")
    expect(provider).to receive(:commit).with(group).and_return(false)
    expect(logger).to receive(:warn).with("DID NOT APPLY: Changes not needed to cats")

    subject.apply(action)
  end

  it "rejects attempts to remove enterprise teams" do
    action = Entitlements::Models::Action.new("cats", team, nil, "enterprise-teams")
    expect(logger).to receive(:fatal).with("cats: GitHub enterprise team membership cannot remove a team")

    expect { subject.apply(action) }.to raise_error(RuntimeError, "Invalid Operation")
  end
end
