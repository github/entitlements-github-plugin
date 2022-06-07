# frozen_string_literal: true
require_relative "../../../spec_helper"

describe Entitlements::Backend::GitHubOrg::Provider do
  let(:config) do
    {
      addr: "https://github.fake/api/v3",
      org: "kittensinc",
      token: "GoPackGo",
      ou: "ou=kittensinc,ou=GitHub,dc=github,dc=fake"
    }
  end

  let(:provider_config) { config.merge(base: config[:ou]).map { |k, v| [k.to_s, v] }.to_h }

  let(:github) { Entitlements::Backend::GitHubOrg::Service.new(config) }

  let(:subject) { described_class.new(config: provider_config) }

  describe "#read" do
    let(:members_and_roles) do
      {
        "alice"   => "member",
        "bob"     => "admin",
        "charles" => "member",
        "david"   => "member"
      }
    end

    let(:member_strings_set) do
      Set.new(%w[alice charles david])
    end

    it "pulls the role name from the distinguished name" do
      allow(subject).to receive(:github).and_return(github)
      allow(github).to receive(:org_members).and_return(members_and_roles)
      result = subject.read("member")
      expect(result).to be_a_kind_of(Entitlements::Models::Group)
      expect(result.member_strings).to eq(member_strings_set)
    end

    it "raises if the role requested is invalid" do
      allow(subject).to receive(:github).and_return(github)
      expect(github).not_to receive(:org_members)
      expect do
        subject.read("kitteh")
      end.to raise_error(ArgumentError, 'Invalid role "kitteh". Supported values: admin, member.')
    end
  end

  describe "#commit" do
    let(:dn) { "cn=admin,ou=kittensinc,ou=Github,dc=github,dc=fake" }
    let(:action) { instance_double(Entitlements::Models::Action) }
    let(:group) { instance_double(Entitlements::Models::Group) }
    let(:implementation) { [{ action: :add, person: "foo" }] }

    it "calls the underlying sync_team method and returns the result" do
      allow(subject).to receive(:github).and_return(github)
      allow(action).to receive(:implementation).and_return(implementation)
      expect(action).to receive(:updated).and_return(group)
      expect(subject).to receive(:role_name).with(group).and_return("admin")
      expect(github).to receive(:sync).with(implementation, "admin").and_return(true)
      expect(subject.commit(action)).to eq(true)
    end
  end

  describe "#role_description" do
    it "returns the description" do
      result = subject.send(:role_description, "admin")
      expect(result).to eq("Users with role admin on organization kittensinc")
    end
  end

  describe "#role_dn" do
    it "returns the distinguished name" do
      result = subject.send(:role_dn, "admin")
      expect(result).to eq("cn=admin,ou=kittensinc,ou=GitHub,dc=github,dc=fake")
    end
  end
end
