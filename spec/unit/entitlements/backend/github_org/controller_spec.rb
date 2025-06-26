# frozen_string_literal: true
require_relative "../../../spec_helper"
require "stringio"

describe Entitlements::Backend::GitHubOrg::Controller do
  let(:people_obj) { Entitlements::Data::People::YAML.new(filename: fixture("people.yaml")) }
  let(:provider) { instance_double(Entitlements::Backend::GitHubOrg::Provider) }
  let(:service) { instance_double(Entitlements::Backend::GitHubOrg::Service) }
  let(:backend_config) { base_backend_config }
  let(:base_backend_config) do
    {
      "org"              => "kittensinc",
      "token"            => "CuteAndCuddlyKittens",
      "type"             => "github_org",
      "base"             => "ou=kittensinc,ou=GitHub,dc=github,dc=com",
      "ignore_not_found" => false
    }
  end
  let(:group_name) { "foo-githuborg" }
  let(:subject) { described_class.new(group_name, backend_config) }

  describe "#calculate" do
    # NOTE: This set of tests provides coverage for `changes` and `categorized_changes`
    # in end-to-end fashion.
    let(:org1_admin_group) do
      Entitlements::Models::Group.new(
        dn: "cn=admin,ou=kittensinc,ou=GitHub,dc=github,dc=com",
        description: "Users with role admin on organization kittensinc",
        members: Set.new(%w[RagaMuffin MAINECOON])
      )
    end

    let(:org1_admin_dn) { org1_admin_group.dn }

    let(:org1_member_group) do
      Entitlements::Models::Group.new(
        dn: "cn=member,ou=kittensinc,ou=GitHub,dc=github,dc=com",
        description: "Users with role member on organization kittensinc",
        members: Set.new(%w[blackmanx HiGhlanDer peterbald].map { |u| "#{u}" })
      )
    end

    let(:org1_member_dn) { org1_member_group.dn }

    let(:org2_admin_group) do
      Entitlements::Models::Group.new(
        dn: "cn=admin,ou=kittensinc2,ou=GitHub,dc=github,dc=fake",
        description: "Users with role admin on organization kittensinc2",
        members: Set.new(%w[russianblue].map { |u| "#{u}" })
      )
    end

    let(:org2_admin_dn) { org2_admin_group.dn }

    let(:org2_member_group) do
      Entitlements::Models::Group.new(
        dn: "cn=member,ou=kittensinc2,ou=GitHub,dc=github,dc=fake",
        description: "Users with role member on organization kittensinc2",
        members: Set.new
      )
    end

    let(:org2_member_dn) { org2_member_group.dn }

    context "with changes" do
      let(:org1_members_response) do
        {
          "toyger"      => "admin",
          "mainecoon"   => "admin",
          "blackmanx"   => "member",
          "highlander"  => "admin",
          "russianblue" => "member",
          "ragamuffin"  => "member"
        }
      end

      let(:org2_members_response) do
        {
          "russianblue" => "admin",
          "blackmanx"   => "member"
        }
      end

      let(:implementation_1) do
        [
          { action: :add, person: "RagaMuffin" },
          { action: :remove, person: "toyger" }
        ]
      end

      let(:implementation_2) do
        [
          { action: :add, person: "peterbald" },
          { action: :add, person: "HiGhlanDer" },
          { action: :remove, person: "russianblue" }
        ]
      end

      it "logs expected output and returns expected actions" do
        allow(Entitlements::Data::Groups::Calculated).to receive(:read_all)
          .with("foo-githuborg", {
            "base"             => "ou=kittensinc,ou=GitHub,dc=github,dc=com",
            "org"              => "kittensinc",
            "token"            => "CuteAndCuddlyKittens",
            "ignore_not_found" => false
          }).and_return(Set.new(%w[admin member].map { |cn| "cn=#{cn},ou=kittensinc,ou=GitHub,dc=github,dc=com" }))
        allow(Entitlements::Data::Groups::Calculated).to receive(:read).with(org1_admin_dn).and_return(org1_admin_group)
        allow(Entitlements::Data::Groups::Calculated).to receive(:read).with(org1_member_dn).and_return(org1_member_group)

        allow(Entitlements::Backend::GitHubOrg::Service).to receive(:new).and_return(service)

        allow(service).to receive(:identifier).and_return("github.com")
        allow(service).to receive(:org).and_return("kittensinc")
        allow(service).to receive(:ou).and_return("ou=kittensinc,ou=GitHub,dc=github,dc=com")
        allow(service).to receive(:org_members).and_return(org1_members_response)
        allow(service).to receive(:pending_members).and_return(Set.new)
        allow(service).to receive(:org_members_from_predictive_cache?).and_return(false)

        expect(subject).to receive(:print_differences) do |arg|
          unless arg[:added] == []
            raise "Unexpected value of added: #{arg.inspect}"
          end
          unless arg[:removed] == []
            raise "Unexpected value of removed: #{arg.inspect}"
          end
          unless arg[:changed].is_a?(Array) &&
            arg[:changed].size == 2 &&
            arg[:changed][0].is_a?(Entitlements::Models::Action) &&
            arg[:changed][0].dn == "cn=admin,ou=kittensinc,ou=GitHub,dc=github,dc=com" &&
            arg[:changed][0].existing.is_a?(Entitlements::Models::Group) &&
            arg[:changed][0].existing.dn == "cn=admin,ou=kittensinc,ou=GitHub,dc=github,dc=com" &&
            arg[:changed][0].updated == org1_admin_group &&
            arg[:changed][0].implementation == implementation_1 &&
            arg[:changed][1].is_a?(Entitlements::Models::Action) &&
            arg[:changed][1].dn == "cn=member,ou=kittensinc,ou=GitHub,dc=github,dc=com" &&
            arg[:changed][1].existing.is_a?(Entitlements::Models::Group) &&
            arg[:changed][1].existing.dn == "cn=member,ou=kittensinc,ou=GitHub,dc=github,dc=com" &&
            arg[:changed][1].updated == org1_member_group &&
            arg[:changed][1].implementation == implementation_2
            raise "Unexpected value of changed(foo-githuborg): #{arg[:changed].inspect}"
          end
        end

        subject.prefetch
        subject.calculate
        expect(subject.actions).to be_a_kind_of(Array)
        expect(subject.actions.size).to eq(2)
      end
    end

    context "with pending members" do
      let(:org1_members_response) do
        {
          "toyger" => "admin",
          "highlander" => "admin",
          "blackmanx" => "member",
          "russianblue" => "member"
        }
      end

      let(:org1_pending_members) { Set.new(%w[ragamuffin peterbald]) }

      let(:org2_members_response) do
        {
          "russianblue" => "admin"
        }
      end

      let(:implementation_1) do
        [
          { action: :add, person: "MAINECOON" },
          { action: :remove, person: "toyger" }
        ]
      end

      let(:implementation_2) do
        [
          { action: :add, person: "HiGhlanDer" },
          { action: :remove, person: "russianblue" }
        ]
      end

      it "logs expected output and returns expected actions" do
        allow(Entitlements::Data::Groups::Calculated).to receive(:read_all)
          .with("foo-githuborg", { "base" => "ou=kittensinc,ou=GitHub,dc=github,dc=com", "org" => "kittensinc", "token" => "CuteAndCuddlyKittens", "ignore_not_found" => false })
          .and_return(Set.new(%w[admin member].map { |cn| "cn=#{cn},ou=kittensinc,ou=GitHub,dc=github,dc=com" }))
        allow(Entitlements::Data::Groups::Calculated).to receive(:read).with(org1_admin_dn).and_return(org1_admin_group)
        allow(Entitlements::Data::Groups::Calculated).to receive(:read).with(org1_member_dn).and_return(org1_member_group)

        allow(Entitlements::Backend::GitHubOrg::Service).to receive(:new).and_return(service)

        allow(service).to receive(:identifier).and_return("github.com")
        allow(service).to receive(:org).and_return("kittensinc")
        allow(service).to receive(:ou).and_return("ou=kittensinc,ou=GitHub,dc=github,dc=com")
        allow(service).to receive(:org_members).and_return(org1_members_response)
        allow(service).to receive(:pending_members).and_return(org1_pending_members)
        allow(service).to receive(:org_members_from_predictive_cache?).and_return(false)

        expect(subject).to receive(:print_differences) do |arg|
          unless arg[:added] == []
            raise "Unexpected value of added: #{arg.inspect}"
          end
          unless arg[:removed] == []
            raise "Unexpected value of removed: #{arg.inspect}"
          end
          unless arg[:changed].is_a?(Array) &&
            arg[:changed].size == 2 &&
            arg[:changed][0].is_a?(Entitlements::Models::Action) &&
            arg[:changed][0].dn == "cn=admin,ou=kittensinc,ou=GitHub,dc=github,dc=com" &&
            arg[:changed][0].existing.is_a?(Entitlements::Models::Group) &&
            arg[:changed][0].existing.dn == "cn=admin,ou=kittensinc,ou=GitHub,dc=github,dc=com" &&
            arg[:changed][0].updated == org1_admin_group &&
            arg[:changed][0].implementation == implementation_1 &&
            arg[:changed][1].is_a?(Entitlements::Models::Action) &&
            arg[:changed][1].dn == "cn=member,ou=kittensinc,ou=GitHub,dc=github,dc=com" &&
            arg[:changed][1].existing.is_a?(Entitlements::Models::Group) &&
            arg[:changed][1].existing.dn == "cn=member,ou=kittensinc,ou=GitHub,dc=github,dc=com" &&
            arg[:changed][1].updated == org1_member_group &&
            arg[:changed][1].implementation == implementation_2
            raise "Unexpected value of changed(foo-githuborg): #{arg[:changed].inspect}"
          end
        end

        subject.prefetch
        subject.calculate
        expect(subject.actions).to be_a_kind_of(Array)
        expect(subject.actions.size).to eq(2)
      end
    end

    context "with pending members who need to be disinvited" do
      let(:org1_members_response) do
        {
          "toyger"      => "admin",
          "highlander"  => "admin",
          "blackmanx"   => "member",
          "russianblue" => "member",
          "ragamuffin"  => "admin",
          "peterbald"   => "admin"
        }
      end

      let(:org1_pending_members) { Set.new(%w[balinese ojosazules]) }

      let(:org2_members_response) do
        {
          "russianblue" => "admin"
        }
      end

      let(:implementation_1) do
        [
          { action: :add, person: "MAINECOON" },
          { action: :remove, person: "toyger" }
        ]
      end

      let(:implementation_2) do
        [
          { action: :add, person: "HiGhlanDer" },
          { action: :add, person: "peterbald" },
          { action: :remove, person: "balinese" },
          { action: :remove, person: "ojosazules" },
          { action: :remove, person: "russianblue" }
        ]
      end

      it "logs expected output and returns expected actions" do
        allow(Entitlements::Data::Groups::Calculated).to receive(:read_all)
          .with("foo-githuborg", { "base" => "ou=kittensinc,ou=GitHub,dc=github,dc=com", "org" => "kittensinc", "token" => "CuteAndCuddlyKittens", "ignore_not_found" => false })
          .and_return(Set.new(%w[admin member].map { |cn| "cn=#{cn},ou=kittensinc,ou=GitHub,dc=github,dc=com" }))
        allow(Entitlements::Data::Groups::Calculated).to receive(:read).with(org1_admin_dn).and_return(org1_admin_group)
        allow(Entitlements::Data::Groups::Calculated).to receive(:read).with(org1_member_dn).and_return(org1_member_group)

        allow(Entitlements::Backend::GitHubOrg::Service).to receive(:new).and_return(service)

        allow(service).to receive(:identifier).and_return("github.com")
        allow(service).to receive(:org).and_return("kittensinc")
        allow(service).to receive(:ou).and_return("ou=kittensinc,ou=GitHub,dc=github,dc=com")
        allow(service).to receive(:org_members).and_return(org1_members_response)
        allow(service).to receive(:pending_members).and_return(org1_pending_members)
        allow(service).to receive(:org_members_from_predictive_cache?).and_return(false)

        expect(subject).to receive(:print_differences) do |arg|
          unless arg[:added] == []
            raise "Unexpected value of added: #{arg.inspect}"
          end
          unless arg[:removed] == []
            raise "Unexpected value of removed: #{arg.inspect}"
          end
          unless arg[:changed].is_a?(Array) &&
            arg[:changed].size == 2 &&
            arg[:changed][0].is_a?(Entitlements::Models::Action) &&
            arg[:changed][0].dn == "cn=admin,ou=kittensinc,ou=GitHub,dc=github,dc=com" &&
            arg[:changed][0].existing.is_a?(Entitlements::Models::Group) &&
            arg[:changed][0].existing.dn == "cn=admin,ou=kittensinc,ou=GitHub,dc=github,dc=com" &&
            arg[:changed][0].updated == org1_admin_group &&
            arg[:changed][0].implementation == implementation_1 &&
            arg[:changed][1].is_a?(Entitlements::Models::Action) &&
            arg[:changed][1].dn == "cn=member,ou=kittensinc,ou=GitHub,dc=github,dc=com" &&
            arg[:changed][1].existing.is_a?(Entitlements::Models::Group) &&
            arg[:changed][1].existing.dn == "cn=member,ou=kittensinc,ou=GitHub,dc=github,dc=com" &&
            arg[:changed][1].updated == org1_member_group &&
            arg[:changed][1].implementation == implementation_2
            raise "Unexpected value of changed(foo-githuborg): #{arg[:changed].inspect}"
          end
        end

        subject.prefetch
        subject.calculate
        expect(subject.actions).to be_a_kind_of(Array)
        expect(subject.actions.size).to eq(2)
      end
    end

    context "with no changes" do
      let(:org1_members_response) do
        {
          "ragamuffin"   => "admin",
          "mainecoon"    => "admin",
          "blackmanx" => "member",
          "highlander" => "member",
          "peterbald" => "member"
        }
      end

      let(:org2_members_response) do
        {
          "russianblue" => "admin"
        }
      end

      it "does not run actions" do
        allow(Entitlements::Data::Groups::Calculated).to receive(:read_all)
          .with("foo-githuborg", { "base" => "ou=kittensinc,ou=GitHub,dc=github,dc=com", "org" => "kittensinc", "token" => "CuteAndCuddlyKittens", "ignore_not_found" => false })
          .and_return(Set.new(%w[admin member].map { |cn| "cn=#{cn},ou=kittensinc,ou=GitHub,dc=github,dc=com" }))
        allow(Entitlements::Data::Groups::Calculated).to receive(:read).with(org1_admin_dn).and_return(org1_admin_group)
        allow(Entitlements::Data::Groups::Calculated).to receive(:read).with(org1_member_dn).and_return(org1_member_group)

        allow(Entitlements::Backend::GitHubOrg::Service).to receive(:new).and_return(service)

        allow(service).to receive(:identifier).and_return("github.com")
        allow(service).to receive(:org).and_return("kittensinc")
        allow(service).to receive(:ou).and_return("ou=kittensinc,ou=GitHub,dc=github,dc=com")
        allow(service).to receive(:org_members).and_return(org1_members_response)
        allow(service).to receive(:pending_members).and_return(Set.new)

        expect(logger).to receive(:debug).with("UNCHANGED: No GitHub organization changes for foo-githuborg:admin")
        expect(logger).to receive(:debug).with("UNCHANGED: No GitHub organization changes for foo-githuborg:member")
        expect(logger).to receive(:debug).with("UNCHANGED: No GitHub organization changes for foo-githuborg")

        subject.prefetch
        subject.calculate
        expect(subject.actions).to eq([])
      end
    end

    context "with invitations disabled via feature flags" do
      let(:backend_config) { base_backend_config.merge("features" => %w[remove]) }

      # admin: Set.new(%w[RagaMuffin MAINECOON].map { |u| "#{u}" })
      # members: Set.new(%w[blackmanx HiGhlanDer peterbald].map { |u| "#{u}" })

      context "with other changes" do
        let(:members_response) do
          {
            "toyger"      => "member",
            "highlander"  => "member",
            "russianblue" => "admin",
            "ragamuffin"  => "member",
            "peterbald"   => "member",
            "mainecoon"   => "admin"
          }
        end
        # invite: blackmanx @ member
        # remove: russianblue @ admin, toyger @ member
        # change: ragamuffin -> admin, mainecoon -> member

        it "handles removals and role changes but does not invite" do
          allow(Entitlements::Data::Groups::Calculated).to receive(:read_all)
            .with("foo-githuborg", { "base" => "ou=kittensinc,ou=GitHub,dc=github,dc=com", "features" => %w[remove], "org" => "kittensinc", "token" => "CuteAndCuddlyKittens", "ignore_not_found" => false })
            .and_return(Set.new(%w[admin member].map { |cn| "cn=#{cn},ou=kittensinc,ou=GitHub,dc=github,dc=com" }))
          allow(Entitlements::Data::Groups::Calculated).to receive(:read).with(org1_admin_dn).and_return(org1_admin_group)
          allow(Entitlements::Data::Groups::Calculated).to receive(:read).with(org1_member_dn).and_return(org1_member_group)

          allow(Entitlements::Backend::GitHubOrg::Service).to receive(:new).and_return(service)

          allow(service).to receive(:identifier).and_return("github.com")
          allow(service).to receive(:org).and_return("kittensinc")
          allow(service).to receive(:ou).and_return("ou=kittensinc,ou=GitHub,dc=github,dc=com")
          allow(service).to receive(:org_members).and_return(members_response)
          allow(service).to receive(:pending_members).and_return(Set.new)
          allow(service).to receive(:org_members_from_predictive_cache?).and_return(false)

          expect(logger).to receive(:info).with("CHANGE cn=admin,ou=kittensinc,ou=GitHub,dc=github,dc=com in foo-githuborg")
          expect(logger).to receive(:info).with(".  - russianblue")
          expect(logger).to receive(:info).with(".  + RagaMuffin")
          expect(logger).to receive(:info).with("CHANGE cn=member,ou=kittensinc,ou=GitHub,dc=github,dc=com in foo-githuborg")
          expect(logger).to receive(:info).with(".  - toyger")
          expect(logger).to receive(:info).with(".  - RagaMuffin")

          expect(logger).to receive(:debug).with("GitHubOrg foo-githuborg:member: Feature `invite` disabled. Not inviting 1 person: blackmanx.")

          subject.prefetch
          subject.calculate

          result = subject.actions
          expect(result).to be_a_kind_of(Array)
          expect(result.size).to eq(2)
          expect(result[0]).to be_a_kind_of(Entitlements::Models::Action)
          expect(result[0].updated).to be_a_kind_of(Entitlements::Models::Group)
          expect(result[0].updated.member_strings).to eq(Set.new([
            "RagaMuffin",
            "MAINECOON"
          ]))
          expect(result[0].implementation).to eq([
            { action: :add, person: "RagaMuffin" },
            { action: :remove, person: "russianblue" }
          ])

          expect(result[1]).to be_a_kind_of(Entitlements::Models::Action)
          expect(result[1].updated).to be_a_kind_of(Entitlements::Models::Group)
          expect(result[1].updated.member_strings).to eq(Set.new([
            "HiGhlanDer",
            "peterbald"
          ]))
          expect(result[1].implementation).to eq([
            { action: :remove, person: "toyger" }
          ])
        end
      end

      context "with only invites" do
        let(:members_response) do
          {
            "mainecoon"  => "admin",
            "highlander" => "member",
            "ragamuffin" => "admin"
          }
        end

        it "reports as a no-op" do
          allow(Entitlements::Data::Groups::Calculated).to receive(:read_all)
            .with("foo-githuborg", { "base" => "ou=kittensinc,ou=GitHub,dc=github,dc=com", "features" => %w[remove], "org" => "kittensinc", "token" => "CuteAndCuddlyKittens", "ignore_not_found" => false })
            .and_return(Set.new(%w[admin member].map { |cn| "cn=#{cn},ou=kittensinc,ou=GitHub,dc=github,dc=com" }))
          allow(Entitlements::Data::Groups::Calculated).to receive(:read).with(org1_admin_dn).and_return(org1_admin_group)
          allow(Entitlements::Data::Groups::Calculated).to receive(:read).with(org1_member_dn).and_return(org1_member_group)

          allow(Entitlements::Backend::GitHubOrg::Service).to receive(:new).and_return(service)

          allow(service).to receive(:identifier).and_return("github.com")
          allow(service).to receive(:org).and_return("kittensinc")
          allow(service).to receive(:ou).and_return("ou=kittensinc,ou=GitHub,dc=github,dc=com")
          allow(service).to receive(:org_members).and_return(members_response)
          allow(service).to receive(:pending_members).and_return(Set.new)

          expect(logger).to receive(:debug).with("UNCHANGED: No GitHub organization changes for foo-githuborg:admin")
          expect(logger).to receive(:debug).with("UNCHANGED: No GitHub organization changes for foo-githuborg:member")
          expect(logger).to receive(:debug).with("UNCHANGED: No GitHub organization changes for foo-githuborg")
          expect(logger).to receive(:debug).with("GitHubOrg foo-githuborg:member: Feature `invite` disabled. Not inviting 2 people: blackmanx, peterbald.")

          subject.prefetch
          subject.calculate
          expect(subject.actions).to be_a_kind_of(Array)
          expect(subject.actions.size).to eq(0)
        end
      end
    end

    context "with removals disabled via feature flags" do
      let(:backend_config) { base_backend_config.merge("features" => %w[invite]) }

      # admin: Set.new(%w[RagaMuffin MAINECOON].map { |u| "#{u}" })
      # members: Set.new(%w[blackmanx HiGhlanDer peterbald].map { |u| "#{u}" })

      context "with other changes" do
        let(:members_response) do
          {
            "toyger"      => "member",
            "highlander"  => "member",
            "russianblue" => "admin",
            "ragamuffin"  => "member",
            "peterbald"   => "member",
            "mainecoon"   => "admin"
          }
        end
        # invite: blackmanx @ member
        # remove: russianblue @ admin, toyger @ member
        # change: ragamuffin -> admin, mainecoon -> member

        it "handles removals and role changes but does not invite" do
          allow(Entitlements::Data::Groups::Calculated).to receive(:read_all)
            .with("foo-githuborg", { "base" => "ou=kittensinc,ou=GitHub,dc=github,dc=com", "features" => %w[invite], "org" => "kittensinc", "token" => "CuteAndCuddlyKittens", "ignore_not_found" => false })
            .and_return(Set.new(%w[admin member].map { |cn| "cn=#{cn},ou=kittensinc,ou=GitHub,dc=github,dc=com" }))
          allow(Entitlements::Data::Groups::Calculated).to receive(:read).with(org1_admin_dn).and_return(org1_admin_group)
          allow(Entitlements::Data::Groups::Calculated).to receive(:read).with(org1_member_dn).and_return(org1_member_group)

          allow(Entitlements::Backend::GitHubOrg::Service).to receive(:new).and_return(service)

          allow(service).to receive(:identifier).and_return("github.com")
          allow(service).to receive(:org).and_return("kittensinc")
          allow(service).to receive(:ou).and_return("ou=kittensinc,ou=GitHub,dc=github,dc=com")
          allow(service).to receive(:org_members).and_return(members_response)
          allow(service).to receive(:pending_members).and_return(Set.new)
          allow(service).to receive(:org_members_from_predictive_cache?).and_return(false)

          expect(logger).to receive(:info).with("CHANGE cn=admin,ou=kittensinc,ou=GitHub,dc=github,dc=com in foo-githuborg")
          expect(logger).to receive(:info).with(".  + blackmanx")
          expect(logger).to receive(:info).with(".  + RagaMuffin")
          expect(logger).to receive(:info).with("CHANGE cn=member,ou=kittensinc,ou=GitHub,dc=github,dc=com in foo-githuborg")
          expect(logger).to receive(:info).with(".  - RagaMuffin")

          expect(logger).to receive(:debug).with("GitHubOrg foo-githuborg:admin: Feature `remove` disabled. Not removing 1 person: russianblue.")
          expect(logger).to receive(:debug).with("GitHubOrg foo-githuborg:member: Feature `remove` disabled. Not removing 1 person: toyger.")

          subject.prefetch
          subject.calculate

          result = subject.actions
          expect(result).to be_a_kind_of(Array)
          expect(result.size).to eq(2)
          expect(result[0]).to be_a_kind_of(Entitlements::Models::Action)
          expect(result[0].updated).to be_a_kind_of(Entitlements::Models::Group)
          expect(result[0].updated.member_strings).to eq(Set.new([
            "russianblue",
            "RagaMuffin",
            "MAINECOON"
          ]))
          expect(result[0].implementation).to eq([
            { action: :add, person: "RagaMuffin" }
          ])

          expect(result[1]).to be_a_kind_of(Entitlements::Models::Action)
          expect(result[1].updated).to be_a_kind_of(Entitlements::Models::Group)
          expect(result[1].updated.member_strings).to eq(Set.new([
            "blackmanx",
            "toyger",
            "HiGhlanDer",
            "peterbald"
          ]))
          expect(result[1].implementation).to eq([
            { action: :add, person: "blackmanx" }
          ])
        end
      end

      context "with only removes" do
        let(:members_response) do
          {
            "toyger"      => "admin",
            "blackmanx"   => "member",
            "russianblue" => "admin",
            "mainecoon"   => "admin",
            "highlander"  => "member",
            "ragamuffin"  => "admin",
            "peterbald"   => "member"
          }
        end

        it "reports as a no-op" do
          allow(Entitlements::Data::Groups::Calculated).to receive(:read_all)
            .with("foo-githuborg", { "base" => "ou=kittensinc,ou=GitHub,dc=github,dc=com", "features" => %w[invite], "org" => "kittensinc", "token" => "CuteAndCuddlyKittens", "ignore_not_found" => false })
            .and_return(Set.new(%w[admin member].map { |cn| "cn=#{cn},ou=kittensinc,ou=GitHub,dc=github,dc=com" }))
          allow(Entitlements::Data::Groups::Calculated).to receive(:read).with(org1_admin_dn).and_return(org1_admin_group)
          allow(Entitlements::Data::Groups::Calculated).to receive(:read).with(org1_member_dn).and_return(org1_member_group)

          allow(Entitlements::Backend::GitHubOrg::Service).to receive(:new).and_return(service)

          allow(service).to receive(:identifier).and_return("github.com")
          allow(service).to receive(:org).and_return("kittensinc")
          allow(service).to receive(:ou).and_return("ou=kittensinc,ou=GitHub,dc=github,dc=com")
          allow(service).to receive(:org_members).and_return(members_response)
          allow(service).to receive(:pending_members).and_return(Set.new)

          expect(logger).to receive(:debug).with("UNCHANGED: No GitHub organization changes for foo-githuborg:admin")
          expect(logger).to receive(:debug).with("UNCHANGED: No GitHub organization changes for foo-githuborg:member")
          expect(logger).to receive(:debug).with("UNCHANGED: No GitHub organization changes for foo-githuborg")
          expect(logger).to receive(:debug).with("GitHubOrg foo-githuborg:admin: Feature `remove` disabled. Not removing 2 people: russianblue, toyger.")

          subject.prefetch
          subject.calculate
          expect(subject.actions).to be_a_kind_of(Array)
          expect(subject.actions.size).to eq(0)
        end
      end
    end

    context "with changes while using predictive cache" do
      let(:admins) { Set.new(%w[monalisa]) }
      let(:members) { Set.new(%w[ocicat blackmanx]) }
      let(:answer) { { "monalisa" => "ADMIN", "ocicat" => "MEMBER", "blackmanx" => "MEMBER" } }
      let(:answer2) { { "monalisa" => "ADMIN", "ragamuffin" => "ADMIN", "blackmanx" => "MEMBER", "toyger" => "MEMBER" } }

      it "invalidates the cache and consults the API" do
        cache[:predictive_state] = { by_dn: { org1_admin_dn => { members: admins, metadata: nil }, org1_member_dn => { members:, metadata: nil } }, invalid: Set.new }

        allow(Entitlements::Data::Groups::Calculated).to receive(:read_all)
          .with("foo-githuborg", { "base" => "ou=kittensinc,ou=GitHub,dc=github,dc=com", "org" => "kittensinc", "token" => "CuteAndCuddlyKittens", "ignore_not_found" => false })
          .and_return(Set.new(%w[admin member].map { |cn| "cn=#{cn},ou=kittensinc,ou=GitHub,dc=github,dc=com" }))

        allow(Entitlements::Data::Groups::Calculated).to receive(:read).with(org1_admin_dn).and_return(org1_admin_group)
        allow(Entitlements::Data::Groups::Calculated).to receive(:read).with(org1_member_dn).and_return(org1_member_group)

        service = subject.send(:provider).github
        expect(service).to receive(:members_and_roles_from_rest).and_return(answer2)
        expect(service).to receive(:pending_members).exactly(2).times.and_return(Set.new)

        expect(logger).to receive(:debug).with("Loading organization members and roles for kittensinc from cache")
        expect(logger).to receive(:debug).with("Currently kittensinc has 1 admin(s) and 2 member(s)")
        expect(logger).to receive(:debug).with("Invalidating cache entries for cn=(admin|member),ou=kittensinc,ou=GitHub,dc=github,dc=com")
        expect(logger).to receive(:debug).with("members(cn=admin,ou=kittensinc,ou=GitHub,dc=github,dc=com): DN has been marked invalid in cache")
        expect(logger).to receive(:debug).with("members(cn=member,ou=kittensinc,ou=GitHub,dc=github,dc=com): DN has been marked invalid in cache")
        expect(logger).to receive(:debug).with("Currently kittensinc has 2 admin(s) and 2 member(s)")

        subject.prefetch
        result = subject.calculate
        expect(result).to be_a_kind_of(Array)
        expect(result.size).to eq(2)
        expect(result[0]).to be_a_kind_of(Entitlements::Models::Action)
        expect(result[0].updated).to be_a_kind_of(Entitlements::Models::Group)
        expect(result[0].updated.member_strings).to eq(org1_admin_group.member_strings)
        expect(result[0].implementation).to eq([
          { action: :add, person: "MAINECOON" }, { action: :remove, person: "monalisa" }
        ])

        expect(result[1]).to be_a_kind_of(Entitlements::Models::Action)
        expect(result[1].updated).to be_a_kind_of(Entitlements::Models::Group)
        expect(result[1].updated.member_strings).to eq(org1_member_group.member_strings)
        expect(result[1].implementation).to eq([
          { action: :add, person: "HiGhlanDer" }, { action: :add, person: "peterbald" }, { action: :remove, person: "toyger" }
        ])
      end
    end

    context "with invitations and removals disabled via feature flags" do
      let(:backend_config) { base_backend_config.merge("features" => %w[]) }

      # admin: Set.new(%w[RagaMuffin MAINECOON].map { |u| "#{u}" })
      # members: Set.new(%w[blackmanx HiGhlanDer peterbald].map { |u| "#{u}" })

      context "with other changes" do
        let(:group_config) do
          {
            "foo-githuborg" => {
              "base"     => "ou=kittensinc,ou=GitHub,dc=github,dc=com",
              "features" => [],
              "org"      => "kittensinc",
              "token"    => "CuteAndCuddlyKittens"
            }
          }
        end

        let(:members_response) do
          {
            "toyger"      => "member",
            "highlander"  => "member",
            "russianblue" => "admin",
            "ragamuffin"  => "member",
            "peterbald"   => "member",
            "mainecoon"   => "admin"
          }
        end
        # invite: blackmanx @ member
        # remove: russianblue @ admin, toyger @ member
        # change: ragamuffin -> admin, mainecoon -> member

        it "handles removals and role changes but does not invite" do
          allow(Entitlements::Data::Groups::Calculated).to receive(:read_all)
            .with("foo-githuborg", { "base" => "ou=kittensinc,ou=GitHub,dc=github,dc=com", "features" => [], "org" => "kittensinc", "token" => "CuteAndCuddlyKittens", "ignore_not_found" => false })
            .and_return(Set.new(%w[admin member].map { |cn| "cn=#{cn},ou=kittensinc,ou=GitHub,dc=github,dc=com" }))
          allow(Entitlements::Data::Groups::Calculated).to receive(:read).with(org1_admin_dn).and_return(org1_admin_group)
          allow(Entitlements::Data::Groups::Calculated).to receive(:read).with(org1_member_dn).and_return(org1_member_group)

          allow(Entitlements::Backend::GitHubOrg::Service).to receive(:new).and_return(service)
          Entitlements.config["groups"].merge!(group_config)

          allow(service).to receive(:identifier).and_return("github.com")
          allow(service).to receive(:org).and_return("kittensinc")
          allow(service).to receive(:ou).and_return("ou=kittensinc,ou=GitHub,dc=github,dc=com")
          allow(service).to receive(:org_members).and_return(members_response)
          allow(service).to receive(:pending_members).and_return(Set.new)
          allow(service).to receive(:org_members_from_predictive_cache?).and_return(false)

          expect(logger).to receive(:info).with("CHANGE cn=admin,ou=kittensinc,ou=GitHub,dc=github,dc=com in foo-githuborg")
          expect(logger).to receive(:info).with(".  + RagaMuffin")
          expect(logger).to receive(:info).with("CHANGE cn=member,ou=kittensinc,ou=GitHub,dc=github,dc=com in foo-githuborg")
          expect(logger).to receive(:info).with(".  - RagaMuffin")

          expect(logger).to receive(:debug).with("GitHubOrg foo-githuborg:member: Feature `invite` disabled. Not inviting 1 person: blackmanx.")
          expect(logger).to receive(:debug).with("GitHubOrg foo-githuborg:admin: Feature `remove` disabled. Not removing 1 person: russianblue.")
          expect(logger).to receive(:debug).with("GitHubOrg foo-githuborg:member: Feature `remove` disabled. Not removing 1 person: toyger.")

          subject.prefetch
          result = subject.calculate
          expect(result).to be_a_kind_of(Array)
          expect(result.size).to eq(2)
          expect(result[0]).to be_a_kind_of(Entitlements::Models::Action)
          expect(result[0].updated).to be_a_kind_of(Entitlements::Models::Group)
          expect(result[0].updated.member_strings).to eq(Set.new([
            "russianblue",
            "RagaMuffin",
            "MAINECOON"
          ]))
          expect(result[0].implementation).to eq([
            { action: :add, person: "RagaMuffin" }
          ])

          expect(result[1]).to be_a_kind_of(Entitlements::Models::Action)
          expect(result[1].updated).to be_a_kind_of(Entitlements::Models::Group)
          expect(result[1].updated.member_strings).to eq(Set.new([
            "toyger",
            "HiGhlanDer",
            "peterbald"
          ]))
          expect(result[1].implementation).to be nil
        end
      end

      context "with only invites & removes" do
        let(:members_response) do
          {
            "toyger"      => "admin",
            "russianblue" => "admin",
            "mainecoon"   => "admin",
            "highlander"  => "member",
            "ragamuffin"  => "admin",
          }
        end

        it "reports as a no-op" do
          allow(Entitlements::Data::Groups::Calculated).to receive(:read_all)
            .with("foo-githuborg", { "base" => "ou=kittensinc,ou=GitHub,dc=github,dc=com", "features" => [], "org" => "kittensinc", "token" => "CuteAndCuddlyKittens", "ignore_not_found" => false })
            .and_return(Set.new(%w[admin member].map { |cn| "cn=#{cn},ou=kittensinc,ou=GitHub,dc=github,dc=com" }))
          allow(Entitlements::Data::Groups::Calculated).to receive(:read).with(org1_admin_dn).and_return(org1_admin_group)
          allow(Entitlements::Data::Groups::Calculated).to receive(:read).with(org1_member_dn).and_return(org1_member_group)

          allow(Entitlements::Backend::GitHubOrg::Service).to receive(:new).and_return(service)

          allow(service).to receive(:identifier).and_return("github.com")
          allow(service).to receive(:org).and_return("kittensinc")
          allow(service).to receive(:ou).and_return("ou=kittensinc,ou=GitHub,dc=github,dc=com")
          allow(service).to receive(:org_members).and_return(members_response)
          allow(service).to receive(:pending_members).and_return(Set.new)

          allow(logger).to receive(:debug)
          expect(logger).to receive(:debug).with("UNCHANGED: No GitHub organization changes for foo-githuborg:admin")
          expect(logger).to receive(:debug).with("UNCHANGED: No GitHub organization changes for foo-githuborg:member")
          expect(logger).to receive(:debug).with("UNCHANGED: No GitHub organization changes for foo-githuborg")
          expect(logger).to receive(:debug).with("GitHubOrg foo-githuborg:admin: Feature `remove` disabled. Not removing 2 people: russianblue, toyger.")
          expect(logger).to receive(:debug).with("GitHubOrg foo-githuborg:member: Feature `invite` disabled. Not inviting 2 people: blackmanx, peterbald.")

          subject.prefetch
          subject.calculate

          expect(subject.actions).to be_a_kind_of(Array)
          expect(subject.actions.size).to eq(0)
        end
      end
    end
  end

  describe "#apply" do
    it "raises upon an attempt to delete something" do
      action = instance_double(Entitlements::Models::Action)
      group = instance_double(Entitlements::Models::Group)
      dn = "cn=kittens,ou=Github,dc=kittens,dc=net"
      allow(action).to receive(:dn).and_return(dn)
      allow(action).to receive(:updated).and_return(nil)
      allow(action).to receive(:existing).and_return(group)
      expect(logger).to receive(:fatal).with("#{dn}: GitHub entitlements interface does not support creating or removing a GitHub org")
      expect do
        subject.apply(action)
      end.to raise_error(RuntimeError, "Invalid Operation")
    end

    it "raises upon an attempt to create something" do
      action = instance_double(Entitlements::Models::Action)
      group = instance_double(Entitlements::Models::Group)
      dn = "cn=kittens,ou=Github,dc=kittens,dc=net"
      allow(action).to receive(:dn).and_return(dn)
      allow(action).to receive(:existing).and_return(nil)
      allow(action).to receive(:updated).and_return(group)
      expect(logger).to receive(:fatal).with("#{dn}: GitHub entitlements interface does not support creating or removing a GitHub org")
      expect do
        subject.apply(action)
      end.to raise_error(RuntimeError, "Invalid Operation")
    end

    it "prints happy path message when action succeeds" do
      action = instance_double(Entitlements::Models::Action)
      group = instance_double(Entitlements::Models::Group)
      dn = "cn=kittens,ou=Github,dc=kittens,dc=net"
      allow(action).to receive(:dn).and_return(dn)
      allow(action).to receive(:existing).and_return(group)
      allow(action).to receive(:updated).and_return(group)
      allow(action).to receive(:ou).and_return("github-ou")
      github_double = instance_double(Entitlements::Backend::GitHubTeam::Provider)
      allow(subject).to receive(:provider).and_return(github_double)
      expect(github_double).to receive(:commit).with(action).and_return(true)
      expect(logger).to receive(:debug).with("APPLY: Updating GitHub organization cn=kittens,ou=Github,dc=kittens,dc=net")
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
      github_double = instance_double(Entitlements::Backend::GitHubTeam::Provider)
      allow(subject).to receive(:provider).and_return(github_double)
      expect(github_double).to receive(:commit).with(action).and_return(false)
      expect(logger).to receive(:debug).exactly(2).times
      expect(logger).to receive(:warn).with("DID NOT APPLY: Changes not needed to cn=kittens,ou=Github,dc=kittens,dc=net")
      subject.apply(action)
    end
  end

  describe "#validate_config!" do
    context "with an invalid feature" do
      let(:config_data) do
        {
          "base"     => "ou=foo,dc=kittens,dc=net",
          "org"      => "kittensinc",
          "token"    => "1234567890abcdef",
          "features" => %w[invite remove kittens]
        }
      end

      it "raises" do
        expect do
          subject.send(:validate_config!, "bar", config_data)
        end.to raise_error(RuntimeError, 'Invalid feature(s) in GitHub organization group "bar": kittens')
      end
    end
  end

  describe "#validate_github_org_ous!" do
    it "raises if an admin or member group is missing" do
      allow(Entitlements::Data::Groups::Calculated).to receive(:read_all)
        .with("foo-githuborg", { "base" => "ou=kittensinc,ou=GitHub,dc=github,dc=com", "org" => "kittensinc", "token" => "CuteAndCuddlyKittens", "ignore_not_found" => false })
        .and_return(Set.new(%w[member].map { |cn| "cn=#{cn},ou=kittensinc,ou=GitHub,dc=github,dc=com" }))

      github_double = instance_double(Entitlements::Backend::GitHubOrg::Provider)
      allow(subject).to receive(:provider).and_return(github_double)
      allow(github_double).to receive(:read).with("cn=member,ou=kittensinc,ou=GitHub,dc=github,dc=com").and_return({})
      allow(github_double).to receive(:read).with("cn=admin,ou=kittensinc,ou=GitHub,dc=github,dc=com").and_return({})

      expect(logger).to receive(:fatal).with("GitHubOrg: No group definition for foo-githuborg:admin - abort!")

      subject.prefetch
      expect do
        subject.send(:validate_github_org_ous!)
      end.to raise_error(RuntimeError, "GitHubOrg must define admin and member roles.")
    end

    it "raises if an unexpected group is found" do
      dns = %w[admin member kittens cats].map { |cn| "cn=#{cn},ou=kittensinc,ou=GitHub,dc=github,dc=com" }

      allow(Entitlements::Data::Groups::Calculated).to receive(:read_all)
        .with("foo-githuborg", { "base" => "ou=kittensinc,ou=GitHub,dc=github,dc=com", "org" => "kittensinc", "token" => "CuteAndCuddlyKittens", "ignore_not_found" => false })
        .and_return(Set.new(dns))

      allow(Entitlements::Backend::GitHubOrg::Service).to receive(:new).and_return(service)
      allow(service).to receive(:org_members).and_return({})

      github_double = instance_double(Entitlements::Backend::GitHubOrg::Provider)
      allow(subject).to receive(:provider).and_return(github_double)
      dns.each do |dn|
        allow(github_double).to receive(:read).with(dn).and_return({})
      end

      expect(logger).to receive(:fatal).with("GitHubOrg: Unexpected role(s) in foo-githuborg: kittens, cats")

      subject.prefetch
      expect { subject.calculate }.to raise_error(RuntimeError, "GitHubOrg unexpected roles.")
    end
  end

  describe "#validate_no_dupes!" do
    let(:admin_group) do
      Entitlements::Models::Group.new(
        dn: "cn=admin,ou=kittensinc,ou=GitHub,dc=github,dc=com",
        members: Set.new(%w[BlackMANX RagaMuffin MAINECOON].map { |u| "#{u}" })
      )
    end

    let(:admin_dn) { admin_group.dn }

    let(:member_group) do
      Entitlements::Models::Group.new(
        dn: "cn=member,ou=kittensinc,ou=GitHub,dc=github,dc=com",
        members: Set.new(%w[blackmanx russianblue].map { |u| "#{u}" })
      )
    end

    let(:member_dn) { member_group.dn }

    it "raises due to duplicate users" do
      allow(Entitlements::Data::Groups::Calculated).to receive(:read_all)
        .with("foo-githuborg", { "base" => "ou=kittensinc,ou=GitHub,dc=github,dc=com", "org" => "kittensinc", "token" => "CuteAndCuddlyKittens", "ignore_not_found" => false })
        .and_return(Set.new(%w[admin member].map { |cn| "cn=#{cn},ou=kittensinc,ou=GitHub,dc=github,dc=com" }))
      allow(Entitlements::Data::Groups::Calculated).to receive(:read).with(admin_dn).and_return(admin_group)
      allow(Entitlements::Data::Groups::Calculated).to receive(:read).with(member_dn).and_return(member_group)
      allow(Entitlements::Data::Groups::Calculated).to receive(:read).with(member_dn).and_return(member_group)

      allow(Entitlements::Backend::GitHubOrg::Service).to receive(:new).and_return(service)
      allow(service).to receive(:org_members).and_return({})

      github_double = instance_double(Entitlements::Backend::GitHubOrg::Provider)
      allow(subject).to receive(:provider).and_return(github_double)
      allow(github_double).to receive(:read).with(admin_dn).and_return(admin_group)
      allow(github_double).to receive(:read).with(member_dn).and_return(member_group)

      expect(logger).to receive(:fatal).with("Users in multiple roles for foo-githuborg: blackmanx")

      subject.prefetch
      expect { subject.send(:validate_no_dupes!) }.to raise_error(Entitlements::Backend::GitHubOrg::DuplicateUserError)
    end
  end

  describe "#changes" do
    # There are no tests here at this time because complete test coverage is provided
    # from the "calculate" method.
  end

  describe "#categorized_changes" do
    # There are no tests here at this time because complete test coverage is provided
    # from the "calculate" method.
  end

  describe "#remove_pending" do
    it "mutates input and returns removed entries" do
      invited = %w[
        alice
        bengal
        Charles
        David
      ]
      pending = Set.new(%w[bengal charles])

      result = subject.send(:remove_pending, invited, pending)

      expect(invited).to eq(%w[alice David])
      expect(result).to eq(Set.new(%w[bengal Charles]))
    end
  end

  describe "#disinvited_users" do
    let(:admins) { %w[alice bengal charles DAVID] }
    let(:admin) { Entitlements::Models::Group.new(dn: "cn=admin,dc=foo", members: Set.new(admins)) }
    let(:members) { %w[edward Frank George harriet] }
    let(:member) { Entitlements::Models::Group.new(dn: "cn=member,dc=foo", members: Set.new(members)) }
    let(:groups) { { "admin" => admin, "member" => member } }

    it "returns an empty array when all pending users are accounted for" do
      pending = Set.new(%w[bengal david frank harriet])
      result = subject.send(:disinvited_users, groups, pending)
      expect(result).to eq([])
    end

    it "returns an array of unaccounted for users" do
      pending = Set.new(%w[bengal manx peterbald])
      result = subject.send(:disinvited_users, groups, pending)
      expected_members = %w[manx peterbald]
      expect(result).to eq(expected_members)
    end
  end
end
