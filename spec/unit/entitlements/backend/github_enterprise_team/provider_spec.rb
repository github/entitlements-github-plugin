# frozen_string_literal: true

require_relative "../../../spec_helper"

describe Entitlements::Backend::GitHubEnterpriseTeam::Provider do
  let(:config) do
    {
      "addr" => "https://github.fake/api/v3",
      "base" => "ou=teams,ou=GitHub,dc=github,dc=fake",
      "enterprise" => "kittensinc",
      "token" => "GoPackGo",
    }
  end
  let(:subject) { described_class.new(config:) }
  let(:service) { instance_double(Entitlements::Backend::GitHubEnterpriseTeam::Service) }
  let(:group) do
    Entitlements::Models::Group.new(
      dn: "cn=cats,ou=teams,ou=GitHub,dc=github,dc=fake",
      members: Set.new(%w[octocat monalisa])
    )
  end
  let(:team) do
    Entitlements::Backend::GitHubTeam::Models::Team.new(
      team_id: -1,
      team_name: "cats",
      members: Set.new(%w[octocat]),
      ou: config.fetch("base"),
      metadata: nil
    )
  end

  before do
    subject.instance_variable_set("@github", service)
  end

  it "reads each team once" do
    expect(service).to receive(:read_team).with(group).once.and_return(team)

    expect(subject.read(group)).to eq(team)
    expect(subject.read(group)).to eq(team)
  end

  it "calculates membership differences" do
    allow(service).to receive(:read_team).with(group).and_return(team)

    expect(subject.diff(group)).to eq(added: Set.new(%w[monalisa]), removed: Set.new)
  end

  it "commits membership differences" do
    allow(service).to receive(:read_team).with(group).and_return(team)
    expect(service).to receive(:sync_team).with(group, team).and_return(true)

    expect(subject.commit(group)).to eq(true)
  end
end
