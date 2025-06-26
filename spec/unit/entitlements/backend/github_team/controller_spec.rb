# frozen_string_literal: true

require_relative "../../../spec_helper"

describe Entitlements::Backend::GitHubTeam::Controller do
  let(:provider) { instance_double(Entitlements::Backend::GitHubTeam::Provider) }
  let(:service) { instance_double(Entitlements::Backend::GitHubTeam::Service) }
  let(:backend_config) { base_backend_config }
  let(:base_backend_config) do
    {
      "org"   => "kittensinc",
      "token" => "CuteAndCuddlyKittens",
      "type"  => "github_team",
      "base"  => "ou=kittensinc,ou=GitHub,dc=github,dc=com",
      "ignore_not_found" => false
    }
  end
  let(:group_name) { "foo-githubteam" }
  let(:subject) { described_class.new(group_name, backend_config) }
  let(:org_member_hash) do
    {
      "blackmanx"   => "admin",
      "RagaMuffin"  => "admin",
      "MAINECOON"   => "admin",
      "BlackManx"   => "member",
      "highlander"  => "member",
      "RUSSIANBLue" => "member"
    }
  end

  describe "#calculate" do
    let(:russian_blue_team) do
      Entitlements::Backend::GitHubTeam::Models::Team.new(
        team_id: 1001,
        team_name: "russian-blues",
        ou: "ou=kittensinc,ou=GitHub,dc=github,dc=com",
        members: Set.new(%w[blackmanx MAINECOON]),
        metadata: { "team_id" => 1001 }
      )
    end

    let(:russian_blue_group) do
      Entitlements::Models::Group.new(
        dn: "cn=russian-blues,ou=kittensinc,ou=GitHub,dc=github,dc=fake",
        description: ":smile_cat:",
        members: Set.new(%w[blackmanx MAINECOON]),
        metadata: { "team_id" => 1001 }
      )
    end

    let(:snowshoe_team) do
      Entitlements::Backend::GitHubTeam::Models::Team.new(
        team_id: 1002,
        team_name: "snowshoes",
        ou: "ou=kittensinc,ou=GitHub,dc=github,dc=com",
        members: Set.new(%w[blackmanx MAINECOON]),
        metadata: { "team_id" => 1002 }
      )
    end

    let(:snowshoe_group) do
      Entitlements::Models::Group.new(
        dn: "cn=snowshoes,ou=kittensinc,ou=GitHub,dc=github,dc=fake",
        description: ":smile_cat:",
        members: Set.new(%w[blackmanx MAINECOON]),
        metadata: { "team_id" => 1002 }
      )
    end

    let(:chicken_team) do
      Entitlements::Backend::GitHubTeam::Models::Team.new(
       team_id: 10001,
       team_name: "chicken",
       ou: "ou=kittensinc,ou=GitHub,dc=github,dc=fake",
       members: Set.new(%w[blackmanx]),
       metadata: { "team_id" => 10001 }
     )
    end

    let(:chicken_group) do
      Entitlements::Models::Group.new(
        dn: "cn=chicken,ou=kittensinc,ou=GitHub,dc=github,dc=fake",
        description: ":smile_cat:",
        members: Set.new(%w[blackmanx]),
        metadata: { "team_id" => 10001 }
      )
    end

    context "with changes" do
      let(:russian_blue_group) do
        Entitlements::Models::Group.new(
          dn: "cn=russian-blues,ou=kittensinc,ou=GitHub,dc=github,dc=com",
          members: Set.new(%w[RagaMuffin MAINECOON]),
          metadata: { "team_id" => 1001 }
        )
      end

      let(:snowshoe_group) do
        Entitlements::Models::Group.new(
          dn: "cn=snowshoes,ou=kittensinc,ou=GitHub,dc=github,dc=com",
          members: Set.new(%w[blackmanx RagaMuffin MAINECOON])
        )
      end

      let(:chicken_group) do
        Entitlements::Models::Group.new(
          dn: "cn=chicken,ou=kittensinc,ou=GitHub,dc=github,dc=fake",
          members: Set.new(%w[BlackManx highlander RUSSIANBLue])
        )
      end

      it "logs expected output and returns expected actions" do
        allow(Entitlements::Data::Groups::Calculated).to receive(:read_all)
          .with("foo-githubteam", { "base" => "ou=kittensinc,ou=GitHub,dc=github,dc=com", "org" => "kittensinc", "token" => "CuteAndCuddlyKittens", "ignore_not_found" => false })
          .and_return(Set.new(%w[snowshoes russian-blues]))
        allow(Entitlements::Data::Groups::Calculated).to receive(:read).with("snowshoes").and_return(snowshoe_group)
        allow(Entitlements::Data::Groups::Calculated).to receive(:read).with("russian-blues").and_return(russian_blue_group)
        allow(Entitlements::Util::Util).to receive(:dns_for_ou).with("foo-githubteam", anything).and_return([russian_blue_group.dn])

        dotcom_obj = instance_double(Entitlements::Backend::GitHubTeam::Service)
        expect(Entitlements::Backend::GitHubTeam::Service).to receive(:new).with(hash_including(addr: nil)).and_return(dotcom_obj)
        allow(dotcom_obj).to receive(:identifier).and_return("github.com")
        allow(dotcom_obj).to receive(:org).and_return("kittensinc")
        allow(dotcom_obj).to receive(:read_team).with(russian_blue_group).and_return(russian_blue_team)
        allow(dotcom_obj).to receive(:read_team).with(snowshoe_group).and_return(snowshoe_team)
        allow(dotcom_obj).to receive(:org_members).and_return(org_member_hash)
        allow(dotcom_obj).to receive(:from_predictive_cache?).and_return(false)

        expect(logger).to receive(:debug).with("Loaded cn=russian-blues,ou=kittensinc,ou=GitHub,dc=github,dc=com (id=1001) with 2 member(s)")
        expect(logger).to receive(:debug).with("Loaded cn=snowshoes,ou=kittensinc,ou=GitHub,dc=github,dc=com (id=1002) with 2 member(s)")

        allow(subject).to receive(:print_differences)

        subject.prefetch
        result = subject.calculate
        expect(result).to be_a_kind_of(Array)
        expect(result.size).to eq(2)

        expect(result[0]).to be_a_kind_of(Entitlements::Models::Action)
        expect(result[0].dn).to eq("snowshoes")
        expect(result[0].existing.member_strings).to eq(Set.new(%w[blackmanx mainecoon]))
        expect(result[0].updated.member_strings).to eq(Set.new(%w[blackmanx RagaMuffin MAINECOON]))

        expect(result[1]).to be_a_kind_of(Entitlements::Models::Action)
        expect(result[1].dn).to eq("russian-blues")
        expect(result[1].existing.member_strings).to eq(Set.new(%w[blackmanx mainecoon]))
        expect(result[1].updated.member_strings).to eq(Set.new(%w[RagaMuffin MAINECOON]))
      end
    end

    context "with no changes" do
      let(:russian_blue_group) do
        Entitlements::Models::Group.new(
          dn: "cn=russian-blues,ou=kittensinc,ou=GitHub,dc=github,dc=com",
          members: Set.new(%w[blAckManx MAINECOON]),
          metadata: { "team_id" => 1001 }
        )
      end

      it "does not run actions if there are no diffs detected" do
        allow(Entitlements::Data::Groups::Calculated).to receive(:read_all)
          .with("foo-githubteam", { "base" => "ou=kittensinc,ou=GitHub,dc=github,dc=com", "org" => "kittensinc", "token" => "CuteAndCuddlyKittens", "ignore_not_found" => false })
          .and_return(Set.new(%w[russian-blues]))
        allow(Entitlements::Data::Groups::Calculated).to receive(:read).with("russian-blues").and_return(russian_blue_group)
        allow(Entitlements::Util::Util).to receive(:dns_for_ou).with("foo-githubteam", anything).and_return([russian_blue_group.dn])

        dotcom_obj = instance_double(Entitlements::Backend::GitHubTeam::Service)
        expect(Entitlements::Backend::GitHubTeam::Service).to receive(:new).with(hash_including(addr: nil)).and_return(dotcom_obj)
        allow(dotcom_obj).to receive(:identifier).and_return("github.com")
        allow(dotcom_obj).to receive(:org).and_return("kittensinc")
        allow(dotcom_obj).to receive(:read_team).with(russian_blue_group).and_return(russian_blue_team)
        allow(dotcom_obj).to receive(:org_members).and_return(org_member_hash)
        allow(dotcom_obj).to receive(:from_predictive_cache?).and_return(false)

        expect(logger).to receive(:debug).with("Loaded cn=russian-blues,ou=kittensinc,ou=GitHub,dc=github,dc=com (id=1001) with 2 member(s)")
        expect(logger).to receive(:debug).with("UNCHANGED: No GitHub team changes for foo-githubteam:russian-blues")

        subject.prefetch
        result = subject.calculate
        expect(result).to eq([])
      end
    end

    context "with new team" do
      let(:russian_blue_group) do
        Entitlements::Models::Group.new(
          dn: "cn=russian-blues,ou=kittensinc,ou=GitHub,dc=github,dc=com",
          members: Set.new(%w[RagaMuffin MAINECOON])
        )
      end

      let(:snowshoe_group) do
        Entitlements::Models::Group.new(
          dn: "cn=snowshoes,ou=kittensinc,ou=GitHub,dc=github,dc=com",
          members: Set.new(%w[blackmanx RagaMuffin MAINECOON])
        )
      end

      let(:chicken_group) do
        Entitlements::Models::Group.new(
          dn: "cn=chicken,ou=kittensinc,ou=GitHub,dc=github,dc=fake",
          members: Set.new(%w[BlackManx highlander RUSSIANBLue])
        )
      end

      it "logs expected output and returns expected actions" do
        allow(Entitlements::Data::Groups::Calculated).to receive(:read_all)
          .with("foo-githubteam", { "base" => "ou=kittensinc,ou=GitHub,dc=github,dc=com", "org" => "kittensinc", "token" => "CuteAndCuddlyKittens", "ignore_not_found" => false })
          .and_return(Set.new(%w[snowshoes russian-blues]))
        allow(Entitlements::Data::Groups::Calculated).to receive(:read).with("snowshoes").and_return(snowshoe_group)
        allow(Entitlements::Data::Groups::Calculated).to receive(:read).with("russian-blues").and_return(russian_blue_group)
        allow(Entitlements::Util::Util).to receive(:dns_for_ou).with("foo-githubteam", anything).and_return([russian_blue_group.dn])

        dotcom_obj = instance_double(Entitlements::Backend::GitHubTeam::Service)
        expect(Entitlements::Backend::GitHubTeam::Service).to receive(:new).with(hash_including(addr: nil)).and_return(dotcom_obj)
        allow(dotcom_obj).to receive(:identifier).and_return("github.com")
        allow(dotcom_obj).to receive(:org).and_return("kittensinc")
        allow(dotcom_obj).to receive(:ou).and_return("GitHub")
        allow(dotcom_obj).to receive(:read_team).with(russian_blue_group).and_return(nil)
        allow(dotcom_obj).to receive(:read_team).with(snowshoe_group).and_return(snowshoe_team)
        allow(dotcom_obj).to receive(:org_members).and_return(org_member_hash)
        allow(dotcom_obj).to receive(:from_predictive_cache?).and_return(false)

        expect(logger).to receive(:debug).with("Loaded cn=snowshoes,ou=kittensinc,ou=GitHub,dc=github,dc=com (id=1002) with 2 member(s)")

        allow(subject).to receive(:print_differences)

        subject.prefetch
        result = subject.calculate
        expect(result).to be_a_kind_of(Array)
        expect(result.size).to eq(2)

        expect(result[0]).to be_a_kind_of(Entitlements::Models::Action)
        expect(result[0].dn).to eq("russian-blues")
        expect(result[0].existing.nil?).to eq(true)
        expect(result[0].updated.member_strings).to eq(Set.new(%w[RagaMuffin MAINECOON]))

        expect(result[1]).to be_a_kind_of(Entitlements::Models::Action)
        expect(result[1].dn).to eq("snowshoes")
        expect(result[1].existing.member_strings).to eq(Set.new(%w[blackmanx mainecoon]))
        expect(result[1].updated.member_strings).to eq(Set.new(%w[blackmanx RagaMuffin MAINECOON]))
      end
    end
  end

  describe "#apply" do
    it "raises upon an attempt to delete a team" do
      action = instance_double(Entitlements::Models::Action)
      group = instance_double(Entitlements::Models::Group)
      dn = "cn=kittens,ou=Github,dc=kittens,dc=net"
      allow(action).to receive(:dn).and_return(dn)
      allow(action).to receive(:updated).and_return(nil)
      allow(action).to receive(:existing).and_return(group)
      expect(logger).to receive(:fatal).with("#{dn}: GitHub entitlements interface does not support removing a team at this point")
      expect do
        subject.apply(action)
      end.to raise_error(RuntimeError, "Invalid Operation")
    end

    context "with cache declared" do
      it "prints happy path message when action succeeds" do
        action = instance_double(Entitlements::Models::Action)
        group = instance_double(Entitlements::Models::Group)
        dn = "cn=kittens,ou=Github,dc=kittens,dc=net"
        allow(action).to receive(:dn).and_return(dn)
        allow(action).to receive(:existing).and_return(group)
        allow(action).to receive(:updated).and_return(group)
        allow(action).to receive(:ou).and_return("github-ou")
        allow(group).to receive(:cn).and_return("kittens")
        expect(logger).to receive(:debug).with("APPLY: Updating GitHub team cn=kittens,ou=Github,dc=kittens,dc=net")
        expect(logger).not_to receive(:warn)
        allow(subject).to receive(:provider).and_return(provider)
        expect(provider).to receive(:commit).with(group).and_return(true)
        expect(provider).to receive(:change_ignored?).with(action).and_return(false)
        subject.apply(action)
      end

      it "prints sad path message when action fails" do
        action = instance_double(Entitlements::Models::Action)
        group = instance_double(Entitlements::Models::Group)
        dn = "cn=kittens,ou=Github,dc=kittens,dc=net"
        allow(action).to receive(:dn).and_return(dn)
        allow(action).to receive(:existing).and_return(group)
        allow(action).to receive(:updated).and_return(group)
        allow(action).to receive(:ou).and_return("github-ou")
        allow(group).to receive(:cn).and_return("kittens")
        expect(logger).to receive(:debug).with(/^Old:/)
        expect(logger).to receive(:debug).with(/^New:/)
        expect(logger).to receive(:warn).with("DID NOT APPLY: Changes not needed to cn=kittens,ou=Github,dc=kittens,dc=net")
        allow(subject).to receive(:provider).and_return(provider)
        expect(provider).to receive(:commit).with(group).and_return(false)
        expect(provider).to receive(:change_ignored?).with(action).and_return(false)
        subject.apply(action)
      end
    end

    context "with an ignored change" do
      it "prints debug message but does not apply" do
        action = instance_double(Entitlements::Models::Action)
        group = instance_double(Entitlements::Models::Group)
        dn = "cn=kittens,ou=Github,dc=kittens,dc=net"
        allow(action).to receive(:dn).and_return(dn)
        allow(action).to receive(:existing).and_return(group)
        allow(action).to receive(:updated).and_return(group)
        allow(action).to receive(:ou).and_return("github-ou")
        allow(group).to receive(:cn).and_return("kittens")
        expect(logger).to receive(:debug).with("SKIP: GitHub team cn=kittens,ou=Github,dc=kittens,dc=net only changes organization non-members or pending members")
        expect(logger).not_to receive(:debug).with("APPLY: Updating GitHub team cn=kittens,ou=Github,dc=kittens,dc=net")
        expect(logger).not_to receive(:warn)
        allow(subject).to receive(:provider).and_return(provider)
        expect(provider).not_to receive(:commit)
        expect(provider).to receive(:change_ignored?).with(action).and_return(true)
        subject.apply(action)
      end
    end
  end
end
