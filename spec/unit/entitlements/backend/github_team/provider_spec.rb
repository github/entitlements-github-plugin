# frozen_string_literal: true
require_relative "../../../spec_helper"

describe Entitlements::Backend::GitHubTeam::Provider do
  let(:config) do
    {
      addr: "https://github.fake/api/v3",
      org: "kittensinc",
      token: "GoPackGo",
      ou: "ou=kittensinc,ou=GitHub,dc=github,dc=fake"
    }
  end

  let(:provider_config) { config.merge(base: config[:ou]).map { |k, v| [k.to_s, v] }.to_h }

  let(:github) { Entitlements::Backend::GitHubTeam::Service.new(config) }

  let(:snowshoe) { Entitlements::Models::Person.new(uid: "snowshoe") }
  let(:russian_blue) { Entitlements::Models::Person.new(uid: "russian_blue") }
  let(:members) { Set.new(%w[SnowShoe russian_blue]) }
  let(:dn) { "cn=cats,ou=Github,dc=github,dc=fake" }
  let(:group) { Entitlements::Models::Group.new(dn: dn, description: ":smile_cat:", members: Set.new([snowshoe, russian_blue]), metadata: {"application_owner" => "russian_blue"}) }
  let(:team) { Entitlements::Backend::GitHubTeam::Models::Team.new(team_id: 1001, team_name: "cats", members: members, ou: "ou=kittensinc,ou=GitHub,dc=github,dc=fake", metadata: {"application_owner" => "russian_blue"}) }
  let(:member_strings_set) { Set.new(members.map(&:downcase)) }
  let(:subject) { described_class.new(config: provider_config) }

  describe "#read" do
    let(:entitlement_group_double) { instance_double(Entitlements::Models::Group) }
    let(:github_group_double) { instance_double(Entitlements::Models::Group) }
    let(:team_cache) { { "cats" => github_group_double } }

    it "returns an entry from the cache without calling the api" do
      allow(subject).to receive(:github).and_return(github)
      expect(github).not_to receive(:read_team)
      expect(entitlement_group_double).to receive(:cn).and_return("cats")
      subject.instance_variable_set("@github_team_cache", team_cache)

      result = subject.read(entitlement_group_double)
      expect(result).to eq(github_group_double)
    end

    it "calls the api as needed to read a team" do
      allow(subject).to receive(:github).and_return(github)
      expect(github).to receive(:read_team).with(entitlement_group_double).and_return(team)
      expect(logger).to receive(:debug).with("Loaded cn=cats,ou=kittensinc,ou=GitHub,dc=github,dc=fake (id=1001) with 2 member(s)")
      expect(entitlement_group_double).to receive(:cn).and_return("cats")
      result = subject.read(entitlement_group_double)
      expect(result).to be_a_kind_of(Entitlements::Models::Group)
      expect(result.member_strings).to eq(Set.new(members.map(&:downcase)))
    end

    it "returns the additional metadata from the entitlement" do
      metadata = {"application_owner" => "russian_blue"}
      allow(subject).to receive(:github).and_return(github)
      expect(github).to receive(:read_team).with(entitlement_group_double).and_return(team)
      expect(logger).to receive(:debug).with("Loaded cn=cats,ou=kittensinc,ou=GitHub,dc=github,dc=fake (id=1001) with 2 member(s)")
      expect(entitlement_group_double).to receive(:cn).and_return("cats")
      result = subject.read(entitlement_group_double)
      expect(result).to eq(team)
      expect(team.metadata).to eq(metadata)
    end

    it "pulls a team identifier from a group object" do
      entitlement_group = Entitlements::Models::Group.new(
        dn: "cn=diff-cats,ou=Github,dc=github,dc=fake",
        members: Set.new,
        metadata: { "team_id" => 1001 }
      )
      allow(subject).to receive(:github).and_return(github)
      expect(github).to receive(:read_team).with(entitlement_group).and_return(team)
      expect(logger).to receive(:debug).with("Loaded cn=cats,ou=kittensinc,ou=GitHub,dc=github,dc=fake (id=1001) with 2 member(s)")
      result = subject.read(entitlement_group)
      expect(result).to be_a_kind_of(Entitlements::Models::Group)
      expect(result.member_strings).to eq(Set.new(members.map(&:downcase)))
    end

    it "creates temp group if the team does not exist" do
      #new_team = Entitlements::Backend::GitHubTeam::Models::Team.new(team_id: -999, team_name: "e-no-kittens", members: Set.new, ou: "ou=Github,dc=github,dc=fake")
      entitlement_group = Entitlements::Models::Group.new(
        dn: "cn=e-no-kittens,ou=Github,dc=github,dc=fake",
        members: Set.new,
        metadata: { "application_owner" => "whiskers" }
      )

      github_team = Entitlements::Backend::GitHubTeam::Models::Team.new(
        team_id: -999,
        team_name: "e-no-kittens",
        members: Set.new,
        ou: "ou=kittensinc,ou=GitHub,dc=github,dc=fake",
        metadata: { "application_owner" => "whiskers", "team_id" => -999 }
      )

      allow(subject).to receive(:github).and_return(github)
      expect(github).to receive(:read_team).with(entitlement_group).and_return(nil)
      results = subject.read(entitlement_group)
      expect(results).to eq(nil)
    end
  end

  describe "#diff" do
    let(:team_identifier) { "grumpy-cats" }
    let(:team_dn) { "cn=#{team_identifier},ou=kittensinc,ou=GitHub,dc=github,dc=fake" }
    let(:group) do
      Entitlements::Models::Group.new(
        dn: team_dn,
        description: ":smile_cat:",
        members: new_members
      )
    end
    let(:old_members) { Set.new(%w[blackmanx ragamuffin russianblue]) }
    let(:empty_result) { { added: Set.new, removed: Set.new } }

    context "with accurate cache and no changes" do
      let(:new_members) { old_members }

      it "does not invalidate the cache" do
        cache[:predictive_state] = { by_dn: { team_dn => { members: old_members, metadata: nil } }, invalid: Set.new }

        expect(logger).to receive(:debug).with("Loading GitHub team github.fake:kittensinc/grumpy-cats from cache")
        expect(logger).to receive(:debug).with("Loaded cn=grumpy-cats,ou=kittensinc,ou=GitHub,dc=github,dc=fake (id=-1) with 3 member(s)")

        allow(subject).to receive(:github).and_return(github)
        expect(github).not_to receive(:graphql_team_data)

        expect(subject.diff(group)).to eq(empty_result)
      end
    end

    context "with inaccurate cache and no changes" do
      let(:new_members) { old_members }

      it "invalidates an incorrect cache entry and returns result based on actual data" do
        cache[:predictive_state] = { by_dn: { team_dn => { members: Set.new, metadata: nil } }, invalid: Set.new }

        expect(logger).to receive(:debug).with("Loading GitHub team github.fake:kittensinc/grumpy-cats from cache")
        expect(logger).to receive(:debug).with("Loaded cn=grumpy-cats,ou=kittensinc,ou=GitHub,dc=github,dc=fake (id=-1) with 0 member(s)")
        expect(logger).to receive(:debug).with("Invalidating cache entry for cn=grumpy-cats,ou=kittensinc,ou=GitHub,dc=github,dc=fake")
        expect(logger).to receive(:debug).with("members(cn=grumpy-cats,ou=kittensinc,ou=GitHub,dc=github,dc=fake): DN has been marked invalid in cache")
        expect(logger).to receive(:debug).with("Loading GitHub team github.fake:kittensinc/grumpy-cats")
        expect(logger).to receive(:debug).with("Loaded cn=grumpy-cats,ou=kittensinc,ou=GitHub,dc=github,dc=fake (id=1001) with 3 member(s)")

        allow(subject).to receive(:github).and_return(github)
        expect(github).to receive(:graphql_team_data).with(team_identifier).and_return(members: old_members, team_id: 1001, parent_team_name: nil)

        expect(subject.diff(group)).to eq(empty_result)
      end
    end

    context "with accurate cache and changes" do
      let(:new_members) { Set.new(%w[mainecoon blackmanx ragamuffin]) }

      it "accurately computes changes" do
        cache[:predictive_state] = { by_dn: { team_dn => { members: old_members, metadata: nil } }, invalid: Set.new }

        allow(subject).to receive(:github).and_return(github)
        expect(github).to receive(:graphql_team_data).with(team_identifier).and_return(members: old_members, team_id: 1001, parent_team_name: nil)

        expect(subject.diff(group)).to eq(added: Set.new(%w[mainecoon]), removed: Set.new(%w[russianblue]))
      end
    end

    context "with new team" do
      let(:new_members) { Set.new(%w[snowshoe russianblue]) }

      it "accurately computes changes" do
        cache[:predictive_state] = { by_dn: { }, invalid: Set.new }

        entitlement_group = Entitlements::Models::Group.new(
          dn: "cn=diff-cats,ou=Github,dc=github,dc=fake",
          members: Set.new(%w[snowshoe russianblue]),
          metadata: { "application_owner" => "whiskers", "team_id" => -999 }
        )

        github_team = Entitlements::Backend::GitHubTeam::Models::Team.new(
          team_id: -999,
          team_name: "diff-cats",
          members: Set.new,
          ou: "ou=kittensinc,ou=GitHub,dc=github,dc=fake",
          metadata: { "application_owner" => "whiskers", "team_id" => -999 }
        )

        allow(subject).to receive(:github).and_return(github)
        expect(subject).to receive(:read).with(entitlement_group).and_return(nil)
        expect(subject).to receive(:create_github_team_group).with(entitlement_group).and_return(github_team)

        expect(subject.diff(entitlement_group)).to eq(added: Set.new(%w[snowshoe russianblue]), removed: Set.new, metadata: { create_team: true })
      end
    end
  end

  describe "#change_ignored?" do
    let(:group1) { Entitlements::Models::Group.new(dn: dn, description: ":smile_cat:", members: Set.new([snowshoe])) }
    let(:group2) { Entitlements::Models::Group.new(dn: dn, description: ":smile_cat:", members: Set.new([russian_blue])) }
    let(:action) { Entitlements::Models::Action.new(dn, group1, group2, "foo", ignored_users: ignored_users) }

    context "all adds/removes ignored" do
      let(:ignored_users) { Set.new([snowshoe, russian_blue].map(&:uid)) }

      it "returns true" do
        expect(subject.change_ignored?(action)).to eq(true)
      end
    end

    context "with an add" do
      let(:ignored_users) { Set.new([snowshoe].map(&:uid)) }

      it "returns false" do
        expect(subject.change_ignored?(action)).to eq(false)
      end
    end

    context "with a remove" do
      let(:ignored_users) { Set.new([russian_blue].map(&:uid)) }

      it "returns false" do
        expect(subject.change_ignored?(action)).to eq(false)
      end
    end
  end

  describe "#commit" do
    it "calls the underlying sync_team method and returns the result" do
      allow(subject).to receive(:github).and_return(github)

      grp = Entitlements::Models::Group.new(
        dn: "cn=diff-cats,ou=Github,dc=github,dc=fake",
        members: Set.new(%w[cuddles fluffy Mittens WHISKERS]),
        metadata: { "team_id" => 10005 }
      )

      team = Entitlements::Backend::GitHubTeam::Models::Team.new(
        team_id: 10005,
        team_name: "diff-cats",
        members: Set.new(%w[CUDDLES fluffy Morris whiskerS]),
        ou: "ou=kittensinc,ou=GitHub,dc=github,dc=fake",
        metadata: { "team_id" => 10005 }
      )

      expect(github).to receive(:read_team).with(grp).and_return(team)
      expect(github).to receive(:sync_team).with(grp, team).and_return(true)

      result = subject.commit(grp)
      expect(result).to eq(true)
    end

    it "calls the underlying sync_team method and returns the result for new team" do
      entitlement_group = Entitlements::Models::Group.new(
          dn: "cn=diff-cats,ou=Github,dc=github,dc=fake",
          members: Set.new,
          metadata: { "application_owner" => "whiskers", "team_id" => -999 }
      )

      github_team = Entitlements::Backend::GitHubTeam::Models::Team.new(
          team_id: -999,
          team_name: "diff-cats",
          members: Set.new,
          ou: "ou=kittensinc,ou=GitHub,dc=github,dc=fake",
          metadata: { "application_owner" => "whiskers", "team_id" => -999 }
      )

      allow(subject).to receive(:github).and_return(github)
      expect(github).to receive(:read_team).with(entitlement_group).and_return(nil)
      expect(github).to receive(:create_team).with({entitlement_group: entitlement_group}).and_return(true)
      expect(github).to receive(:invalidate_predictive_cache).with(entitlement_group).and_return(nil)
      expect(github).to receive(:read_team).with(entitlement_group).and_return(github_team)
      expect(github).to receive(:sync_team).with(entitlement_group, github_team).and_return(true)

      result = subject.commit(entitlement_group)
      expect(result).to eq(true)
    end
  end

  describe "#diff_existing_updated" do
    it "returns the correct case-insensitive hash" do
      old_grp = Entitlements::Models::Group.new(
          dn: "cn=diff-cats,ou=Github,dc=github,dc=fake",
          members: Set.new(%w[cuddles fluffy morris WHISKERS].map { |u| "uid=#{u},ou=People,dc=kittens,dc=net" }),
          metadata: { "team_id" => -999 }
      )

      new_grp = Entitlements::Models::Group.new(
          dn: "cn=diff-cats,ou=Github,dc=github,dc=fake",
          members: Set.new(%w[cuddles fluffy Mittens WHISKERS].map { |u| "uid=#{u},ou=People,dc=kittens,dc=net" }),
          metadata: { "team_id" => -999 }
      )

      result = subject.diff_existing_updated(old_grp, new_grp)
      expect(result).to eq(
          added: Set.new(%w[uid=Mittens,ou=People,dc=kittens,dc=net]),
          removed: Set.new(%w[uid=morris,ou=People,dc=kittens,dc=net]),
          metadata: { create_team: true }
      )
    end

    it "diffs parent team change" do
      entitlements_group = Entitlements::Models::Group.new(
        dn: "cn=diff-cats,ou=Github,dc=github,dc=fake",
        members: Set.new(%w[cuddles fluffy morris WHISKERS].map { |u| "uid=#{u},ou=People,dc=kittens,dc=net" }),
        metadata: { "parent_team_name" => "old-parent" }
      )

      github_team = Entitlements::Backend::GitHubTeam::Models::Team.new(
        team_id: 2222,
        team_name: "diff-cats",
        members: Set.new(%w[cuddles fluffy morris WHISKERS].map { |u| "uid=#{u},ou=People,dc=kittens,dc=net" }),
        ou: "ou=kittensinc,ou=GitHub,dc=github,dc=fake",
        metadata: { "parent_team_name" => "new-parent" }
      )

      result = subject.diff_existing_updated(entitlements_group, github_team)
      expect(result).to eq(
        added: Set.new,
        removed: Set.new,
        metadata: { parent_team: "change" }
      )
    end

    it "diffs parent team add" do
      entitlements_group = Entitlements::Models::Group.new(
        dn: "cn=diff-cats,ou=Github,dc=github,dc=fake",
        members: Set.new(%w[cuddles fluffy morris WHISKERS].map { |u| "uid=#{u},ou=People,dc=kittens,dc=net" }),
        metadata: { }
      )

      github_team = Entitlements::Backend::GitHubTeam::Models::Team.new(
        team_id: 2222,
        team_name: "diff-cats",
        members: Set.new(%w[cuddles fluffy morris WHISKERS].map { |u| "uid=#{u},ou=People,dc=kittens,dc=net" }),
        ou: "ou=kittensinc,ou=GitHub,dc=github,dc=fake",
        metadata: { "parent_team_name" => "new-parent" }
      )

      result = subject.diff_existing_updated(entitlements_group, github_team)
      expect(result).to eq(
        added: Set.new,
        removed: Set.new,
        metadata: { parent_team: "add" }
      )
    end

    it "diffs parent team removal" do
      entitlements_group = Entitlements::Models::Group.new(
        dn: "cn=diff-cats,ou=Github,dc=github,dc=fake",
        members: Set.new(%w[cuddles fluffy morris WHISKERS].map { |u| "uid=#{u},ou=People,dc=kittens,dc=net" }),
        metadata: { "parent_team_name" => "new-parent" }
      )

      github_team = Entitlements::Backend::GitHubTeam::Models::Team.new(
        team_id: 2222,
        team_name: "diff-cats",
        members: Set.new(%w[cuddles fluffy morris WHISKERS].map { |u| "uid=#{u},ou=People,dc=kittens,dc=net" }),
        ou: "ou=kittensinc,ou=GitHub,dc=github,dc=fake",
        metadata: { }
      )

      result = subject.diff_existing_updated(entitlements_group, github_team)
      expect(result).to eq(
        added: Set.new,
        removed: Set.new,
        metadata: { parent_team: "remove" }
      )
    end
  end

  describe "#create_github_team_group" do
    it "returns a new empty team" do
      entitlement_group = Entitlements::Models::Group.new(
        dn: "cn=new-kittens,ou=Github,dc=github,dc=fake",
        members: Set.new(%w[cuddles fluffy morris WHISKERS].map { |u| "uid=#{u},ou=People,dc=kittens,dc=net" }),
        metadata: { }
      )

      github_team = Entitlements::Backend::GitHubTeam::Models::Team.new(
        team_id: -999,
        team_name: "new-kittens",
        members: Set.new,
        ou: "ou=kittensinc,ou=GitHub,dc=github,dc=fake",
        metadata: {"team_id" => -999}
      )

      result = subject.send(:create_github_team_group, entitlement_group)
      expect(result).to eq(github_team)
      expect(result.metadata).to eq(github_team.metadata)
    end

    it "returns a new empty team, handling NoMetadata" do
      entitlement_group = Entitlements::Models::Group.new(
        dn: "cn=new-kittens,ou=Github,dc=github,dc=fake",
        members: Set.new(%w[cuddles fluffy morris WHISKERS].map { |u| "uid=#{u},ou=People,dc=kittens,dc=net" })
      )

      github_team = Entitlements::Backend::GitHubTeam::Models::Team.new(
        team_id: -999,
        team_name: "new-kittens",
        members: Set.new,
        ou: "ou=kittensinc,ou=GitHub,dc=github,dc=fake",
        metadata: {"team_id" => -999}
      )

      result = subject.send(:create_github_team_group, entitlement_group)
      expect(result).to eq(github_team)
      expect(result.metadata).to eq(github_team.metadata)
    end
  end
end
