# frozen_string_literal: true

require_relative "../../../spec_helper"

require "json"
require "ostruct"

describe Entitlements::Backend::GitHubOrg::Service do
  let(:subject) do
    described_class.new(
      addr: "https://github.fake/api/v3",
      org: "kittensinc",
      token: "GoPackGo",
      ou: "ou=kittensinc,ou=GitHub,dc=github,dc=fake"
    )
  end

  describe "#sync" do
    it "returns false when there were no changes to be made" do
      expect(logger).to receive(:debug).with(/sync\(admin\): Added 0, removed 0/)
      result = subject.sync([], "admin")
      expect(result).to eq(false)
    end

    it "returns true when there were additions" do
      implementation = [
        { action: :add, person: "uid=HIGhlander,ou=People,dc=kittens,dc=net" }
      ]
      expect(subject).to receive(:add_user_to_organization).with("highlander", "admin").and_return(true)
      expect(logger).to receive(:debug).with(/sync\(admin\): Added 1, removed 0/)
      result = subject.sync(implementation, "admin")
      expect(result).to eq(true)
    end

    it "returns true when there were removals" do
      implementation = [
        { action: :remove, person: "uid=BlackMANX,ou=People,dc=kittens,dc=net" }
      ]
      expect(subject).to receive(:remove_user_from_organization).with("blackmanx").and_return(true)
      expect(logger).to receive(:debug).with(/sync\(admin\): Added 0, removed 1/)
      result = subject.sync(implementation, "admin")
      expect(result).to eq(true)
    end

    it "returns true when there were additions and removals" do
      implementation = [
        { action: :remove, person: "uid=BlackMANX,ou=People,dc=kittens,dc=net" },
        { action: :add, person: "uid=HIGhlander,ou=People,dc=kittens,dc=net" },
        { action: :add, person: "uid=maiNecOon,ou=People,dc=kittens,dc=net" }
      ]
      expect(subject).to receive(:remove_user_from_organization).with("blackmanx").and_return(true)
      expect(subject).to receive(:add_user_to_organization).with("highlander", "admin").and_return(true)
      expect(subject).to receive(:add_user_to_organization).with("mainecoon", "admin").and_return(true)
      expect(logger).to receive(:debug).with(/sync\(admin\): Added 2, removed 1/)
      result = subject.sync(implementation, "admin")
      expect(result).to eq(true)
    end

    it "returns false when there were no actual additions and removals" do
      implementation = [
        { action: :remove, person: "uid=BlackMANX,ou=People,dc=kittens,dc=net" },
        { action: :add, person: "uid=HIGhlander,ou=People,dc=kittens,dc=net" },
        { action: :add, person: "uid=maiNecOon,ou=People,dc=kittens,dc=net" }
      ]
      expect(subject).to receive(:remove_user_from_organization).with("blackmanx").and_return(false)
      expect(subject).to receive(:add_user_to_organization).with("highlander", "admin").and_return(false)
      expect(subject).to receive(:add_user_to_organization).with("mainecoon", "admin").and_return(false)
      expect(logger).to receive(:debug).with(/sync\(admin\): Added 0, removed 0/)
      result = subject.sync(implementation, "admin")
      expect(result).to eq(false)
    end
  end

  describe "#add_user_to_organization" do
    context "happy path" do
      it "returns true" do
        expect(logger).to receive(:debug).with("github.fake add_user_to_organization(user=bob, org=kittensinc, role=admin)")
        expect(logger).to receive(:debug).with("Setting up GitHub API connection to https://github.fake/api/v3/")
        stub_request(:put, "https://github.fake/api/v3/orgs/kittensinc/memberships/bob").to_return(
          status: 200,
          headers: {
            "Content-type" => "application/json"
          },
          body: JSON.generate(
            "url"   => "https://github.fake/api/v3/orgs/kittensinc/memberships/bob",
            "state" => "pending",
            "role"  => "admin"
          )
        )

        org_members = Set.new
        allow(subject).to receive(:org_members).and_return(org_members)

        pending_members = Set.new
        allow(subject).to receive(:pending_members).and_return(pending_members)

        result = subject.send(:add_user_to_organization, "bob", "admin")
        expect(result).to eq(true)
        expect(subject.org_members).to eq(Set.new)
        expect(subject.pending_members).to eq(Set.new(%w[bob]))
      end
    end

    context "happy path - member is immediately active" do
      it "returns true" do
        expect(logger).to receive(:debug).with("github.fake add_user_to_organization(user=bob, org=kittensinc, role=admin)")
        expect(logger).to receive(:debug).with("Setting up GitHub API connection to https://github.fake/api/v3/")
        stub_request(:put, "https://github.fake/api/v3/orgs/kittensinc/memberships/bob").to_return(
          status: 200,
          headers: {
            "Content-type" => "application/json"
          },
          body: JSON.generate(
            "url"   => "https://github.fake/api/v3/orgs/kittensinc/memberships/bob",
            "state" => "active",
            "role"  => "admin"
          )
        )

        org_members = {}
        allow(subject).to receive(:org_members).and_return(org_members)

        pending_members = Set.new
        allow(subject).to receive(:pending_members).and_return(pending_members)

        result = subject.send(:add_user_to_organization, "bob", "admin")
        expect(result).to eq(true)
        expect(subject.pending_members).to eq(Set.new)
        expect(subject.org_members).to eq("bob" => "admin")
      end
    end

    context "sad path" do
      it "returns false" do
        expect(logger).to receive(:debug).with("github.fake add_user_to_organization(user=bob, org=kittensinc, role=admin)")
        expect(logger).to receive(:debug).with("Setting up GitHub API connection to https://github.fake/api/v3/")
        expect(logger).to receive(:debug).with("{}\n")
        expect(logger).to receive(:error).with("Failed to adjust membership for bob in organization kittensinc with role admin!")

        stub_request(:put, "https://github.fake/api/v3/orgs/kittensinc/memberships/bob").to_return(
          status: 200,
          headers: {
            "Content-type" => "application/json"
          },
          body: "{}"
        )

        result = subject.send(:add_user_to_organization, "bob", "admin")
        expect(result).to eq(false)
      end
    end
  end

  describe "#remove_user_from_organization" do
    it "returns the response from the octokit call" do
      expect(logger).to receive(:debug).with("github.fake remove_user_from_organization(user=bob, org=kittensinc)")
      expect(logger).to receive(:debug).with("Setting up GitHub API connection to https://github.fake/api/v3/")

      stub_request(:delete, "https://github.fake/api/v3/orgs/kittensinc/memberships/bob").to_return(status: 204)

      org_members = { "bob" => "admin" }
      allow(subject).to receive(:org_members).and_return(org_members)

      pending_members = Set.new
      allow(subject).to receive(:pending_members).and_return(pending_members)

      result = subject.send(:remove_user_from_organization, "bob")
      expect(result).to eq(true)
      expect(subject.pending_members).to eq(Set.new)
      expect(subject.org_members).to eq({})
    end
  end
end
