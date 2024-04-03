# frozen_string_literal: true

require_relative "../../../spec_helper"

require "json"
require "ostruct"

describe Entitlements::Backend::GitHubTeam::Service do
  let(:subject) do
    described_class.new(
      addr: "https://github.fake/api/v3",
      org: "kittensinc",
      token: "GoPackGo",
      ou: "ou=kittensinc,ou=GitHub,dc=github,dc=fake",
      ignore_not_found: false
    )
  end

  let(:entitlement_group_exists) do
    Entitlements::Models::Group.new(
      dn: "cn=cuddly-kittens,ou=kittensinc,ou=GitHub,dc=github,dc=fake",
      description: ":smile_cat:",
      members: Set.new(%w[russian-blue snowshoe tabby siamese housecat tiger]),
      metadata: {"application_owner" => "russian_blue"}
    )
  end

  let(:entitlement_group_parent_team) do
    Entitlements::Models::Group.new(
      dn: "cn=cuddly-kittens,ou=kittensinc,ou=GitHub,dc=github,dc=fake",
      description: ":smile_cat:",
      members: Set.new(%w[russian-blue snowshoe tabby siamese housecat tiger]),
      metadata: {"parent_team_name" => "parent-cats"}
    )
  end

  let(:entitlement_group_exists_no_metadata) do
    Entitlements::Models::Group.new(
      dn: "cn=cuddly-kittens,ou=kittensinc,ou=GitHub,dc=github,dc=fake",
      description: ":smile_cat:",
      members: Set.new(%w[russian-blue snowshoe tabby siamese housecat tiger]),
      metadata: nil
    )
  end

  let(:entitlement_group_doesnt_exist) do
    Entitlements::Models::Group.new(
      dn: "cn=team-does-not-exist,ou=kittensinc,ou=GitHub,dc=github,dc=fake",
      description: ":smile_cat:",
      members: Set.new,
      metadata: {}
    )
  end

  let(:cuddly_kittens) do
    Entitlements::Backend::GitHubTeam::Models::Team.new(
      team_id: 1234567,
      team_name: "cuddly-kittens",
      members: Set.new(%w[russian-blue snowshoe tabby siamese housecat tiger]),
      ou: "cuteness",
      metadata: {"application_owner" => "russian_blue"}
    )
  end

  let(:cuddly_kittens_no_metadata) do
    Entitlements::Backend::GitHubTeam::Models::Team.new(
      team_id: 1234567,
      team_name: "cuddly-kittens",
      members: Set.new(%w[russian-blue snowshoe tabby siamese housecat tiger]),
      ou: "cuteness",
      metadata: nil
    )
  end

  let(:team_identifier) { "cuddly-kittens" }
  let(:team_dn) { "cn=cuddly-kittens,ou=kittensinc,ou=GitHub,dc=github,dc=fake" }

  describe "#read_team" do
    it "returns nil when the team does not exist" do
      graphql_response = '{"data":{"organization":{"team":null}}}'
      stub_request(:post, "https://github.fake/api/v3/graphql").
        with(
          body: "{\"query\":\"{\\norganization(login: \\\"kittensinc\\\") {\\nteam(slug: \\\"team-does-not-exist\\\") {\\ndatabaseId\\nparentTeam {\\nslug\\n}\\nmembers(first: 100, membership: IMMEDIATE) {\\nedges {\\nnode {\\nlogin\\n}\\nrole\\ncursor\\n}\\n}\\n}\\n}\\n}\"}"
        ).to_return(status: 200, body: graphql_response)

      expect(logger).to receive(:debug).with("Setting up GitHub API connection to https://github.fake/api/v3/")
      expect(logger).to receive(:debug).with("Loading GitHub team github.fake:kittensinc/team-does-not-exist")
      expect(logger).to receive(:warn).with("Team team-does-not-exist does not exist in this GitHub.com organization. If applied, the team will be created.")
      result = subject.read_team(entitlement_group_doesnt_exist)
      expect(result).to eq(nil)
    end

    it "returns a Entitlements::Backend::GitHubTeam::Models::Team object when the team exists" do
      stub_request(:post, "https://github.fake/api/v3/graphql").
        with(
          body: "{\"query\":\"{\\norganization(login: \\\"kittensinc\\\") {\\nteam(slug: \\\"cuddly-kittens\\\") {\\ndatabaseId\\nparentTeam {\\nslug\\n}\\nmembers(first: 100, membership: IMMEDIATE) {\\nedges {\\nnode {\\nlogin\\n}\\nrole\\ncursor\\n}\\n}\\n}\\n}\\n}\"}"
        ).to_return(status: 200, body: graphql_response(cuddly_kittens, 0, 100))

      expect(logger).to receive(:debug).with("Setting up GitHub API connection to https://github.fake/api/v3/")
      expect(logger).to receive(:debug).with("Loading GitHub team github.fake:kittensinc/cuddly-kittens")
      expect(logger).not_to receive(:warn)

      result = subject.read_team(entitlement_group_exists)
      expect(result).to be_a_kind_of(Entitlements::Backend::GitHubTeam::Models::Team)
      expect(result.team_id).to be_an(Integer)
      expect(result.team_name).to eq("cuddly-kittens")
      expect(result.members).to eq(cuddly_kittens.members)
    end

    it "returns a Entitlements::Backend::GitHubTeam::Models::Team object with parent team when the team exists" do
      stub_request(:post, "https://github.fake/api/v3/graphql").
        with(
          body: "{\"query\":\"{\\norganization(login: \\\"kittensinc\\\") {\\nteam(slug: \\\"cuddly-kittens\\\") {\\ndatabaseId\\nparentTeam {\\nslug\\n}\\nmembers(first: 100, membership: IMMEDIATE) {\\nedges {\\nnode {\\nlogin\\n}\\nrole\\ncursor\\n}\\n}\\n}\\n}\\n}\"}"
        ).to_return(status: 200, body: graphql_response(cuddly_kittens, 0, 100, parent_team: "parent-cats"))

      expect(logger).to receive(:debug).with("Setting up GitHub API connection to https://github.fake/api/v3/")
      expect(logger).to receive(:debug).with("Loading GitHub team github.fake:kittensinc/cuddly-kittens")
      expect(logger).not_to receive(:warn)

      result = subject.read_team(entitlement_group_exists)
      expect(result).to be_a_kind_of(Entitlements::Backend::GitHubTeam::Models::Team)
      expect(result.team_id).to be_an(Integer)
      expect(result.team_name).to eq("cuddly-kittens")
      expect(result.members).to eq(cuddly_kittens.members)
      expect(result.metadata.key?("parent_team_name")).to eq(true)
      expect(result.metadata["parent_team_name"]).to eq("parent-cats")
    end

    it "returns a Entitlements::Backend::GitHubTeam::Models::Team object with parent team when the team exists but has empty entitlement metadata" do
      stub_request(:post, "https://github.fake/api/v3/graphql").
        with(
          body: "{\"query\":\"{\\norganization(login: \\\"kittensinc\\\") {\\nteam(slug: \\\"cuddly-kittens\\\") {\\ndatabaseId\\nparentTeam {\\nslug\\n}\\nmembers(first: 100, membership: IMMEDIATE) {\\nedges {\\nnode {\\nlogin\\n}\\nrole\\ncursor\\n}\\n}\\n}\\n}\\n}\"}"
        ).to_return(status: 200, body: graphql_response(cuddly_kittens_no_metadata, 0, 100, parent_team: "parent-cats"))

      expect(logger).to receive(:debug).with("Setting up GitHub API connection to https://github.fake/api/v3/")
      expect(logger).to receive(:debug).with("Loading GitHub team github.fake:kittensinc/cuddly-kittens")
      expect(logger).not_to receive(:warn)

      result = subject.read_team(entitlement_group_exists_no_metadata)
      expect(result).to be_a_kind_of(Entitlements::Backend::GitHubTeam::Models::Team)
      expect(result.team_id).to be_an(Integer)
      expect(result.team_name).to eq("cuddly-kittens")
      expect(result.members).to eq(cuddly_kittens_no_metadata.members)
      expect(result.metadata.key?("parent_team_name")).to eq(true)
      expect(result.metadata["parent_team_name"]).to eq("parent-cats")
    end

    it "returns a Entitlements::Backend::GitHubTeam::Models::Team object when forced to paginate" do
      allow(subject).to receive(:max_graphql_results).and_return(3)

      stub_request(:post, "https://github.fake/api/v3/graphql")
        .to_return(
          { status: 200, body: graphql_response(cuddly_kittens, 0, 3) },
          { status: 200, body: graphql_response(cuddly_kittens, 3, 3) },
          { status: 200, body: graphql_response(cuddly_kittens, 6, 3) }
        )

      expect(logger).to receive(:debug).with("Setting up GitHub API connection to https://github.fake/api/v3/")
      expect(logger).to receive(:debug).with("Loading GitHub team github.fake:kittensinc/cuddly-kittens")
      expect(logger).not_to receive(:warn)

      result = subject.read_team(entitlement_group_exists)
      expect(result).to be_a_kind_of(Entitlements::Backend::GitHubTeam::Models::Team)
      expect(result.team_id).to be_an(Integer)
      expect(result.team_name).to eq("cuddly-kittens")
      expect(result.member_strings).to eq(cuddly_kittens.member_strings)
    end

    it "retrieves a value from the predictive cache" do
      people = Set.new(%w[blackmanx ragamuffin russianblue])
      Entitlements.cache[:predictive_state] = { by_ou: {}, by_dn: { team_dn => { members: people, metadata: nil } }, invalid: Set.new }
      expect(logger).to receive(:debug).with("Loading GitHub team github.fake:kittensinc/cuddly-kittens from cache")

      result = subject.read_team(entitlement_group_exists)
      expect(result).to be_a_kind_of(Entitlements::Backend::GitHubTeam::Models::Team)
      expect(result.team_id).to eq(-1)
      expect(result.team_name).to eq("cuddly-kittens")
      expect(result.member_strings).to eq(people)
    end

    it "retrieves a value from the predictive cache with no entitlement metadata" do

      people = Set.new(%w[blackmanx ragamuffin russianblue])
      Entitlements.cache[:predictive_state] = { by_ou: {}, by_dn: { team_dn => { members: people, metadata: { "parent_team_name" => "parent-cats" } } }, invalid: Set.new }
      expect(logger).to receive(:debug).with("Loading GitHub team github.fake:kittensinc/cuddly-kittens from cache")

      result = subject.read_team(entitlement_group_exists_no_metadata)
      expect(result).to be_a_kind_of(Entitlements::Backend::GitHubTeam::Models::Team)
      expect(result.team_id).to eq(-1)
      expect(result.team_name).to eq("cuddly-kittens")
      expect(result.member_strings).to eq(people)
    end

    it "retrieves a value with metadata from the predictive cache" do
      people = Set.new(%w[blackmanx ragamuffin russianblue])
      Entitlements.cache[:predictive_state] = { by_ou: {}, by_dn: { team_dn => { members: people, metadata: { "application_owner" => "cheetoh" } } }, invalid: Set.new }
      expect(logger).to receive(:debug).with("Loading GitHub team github.fake:kittensinc/cuddly-kittens from cache")

      result = subject.read_team(entitlement_group_exists)
      expect(result).to be_a_kind_of(Entitlements::Backend::GitHubTeam::Models::Team)
      expect(result.team_id).to eq(-1)
      expect(result.team_name).to eq("cuddly-kittens")
      expect(result.member_strings).to eq(people)
      expect(result.metadata.key?("application_owner")).to eq(true)
    end

    it "has value from the cache take precedence over value from the file" do
      people = Set.new(%w[blackmanx ragamuffin russianblue])
      Entitlements.cache[:predictive_state] = { by_ou: {}, by_dn: { team_dn => { members: people, metadata: { "application_owner" => "cheetoh" } } }, invalid: Set.new }
      expect(logger).to receive(:debug).with("Loading GitHub team github.fake:kittensinc/cuddly-kittens from cache")

      result = subject.read_team(entitlement_group_exists)
      expect(result).to be_a_kind_of(Entitlements::Backend::GitHubTeam::Models::Team)
      expect(result.team_id).to eq(-1)
      expect(result.team_name).to eq("cuddly-kittens")
      expect(result.member_strings).to eq(people)
      expect(result.metadata.key?("application_owner")).to eq(true)
      expect(result.metadata["application_owner"]).to eq("cheetoh")
    end
  end

  describe "#from_predictive_cache?" do
    let(:people) { Set.new(%w[blackmanx ragamuffin russianblue]) }

    context "when not in the cache" do
      it "returns false" do
        cache[:predictive_state] = { by_dn: {}, invalid: Set.new }

        expect(subject).to receive(:graphql_team_data).and_return(members: people.to_a, team_id: 1234567, roles: Hash[*people.collect { |u| [u, "member"] }.flatten])
        expect(logger).to receive(:debug).with("members(#{team_dn}): DN does not exist in cache")
        expect(logger).to receive(:debug).with("Loading GitHub team github.fake:kittensinc/cuddly-kittens")

        expect(subject.from_predictive_cache?(entitlement_group_exists)).to eq(false)
      end
    end

    context "when sourced from the cache" do
      it "returns true" do
        cache[:predictive_state] = { by_dn: { team_dn => { members: people, metadata: nil } }, invalid: Set.new }
        expect(subject).not_to receive(:graphql_team_data)
        expect(logger).to receive(:debug).with("Loading GitHub team github.fake:kittensinc/cuddly-kittens from cache")
        expect(subject.from_predictive_cache?(entitlement_group_exists)).to eq(true)
      end
    end
  end

  describe "#invalidate_predictive_cache" do
    let(:people) { Set.new(%w[blackmanx ragamuffin russianblue]) }

    it "invaliates the cache" do
      cache[:predictive_state] = { by_dn: { team_dn => { members: people, metadata: nil } }, invalid: Set.new }

      # First load should read from the cache.
      team_1 = subject.read_team(entitlement_group_exists)
      expect(team_1.team_id).to eq(-1)
      expect(team_1.member_strings).to eq(people)

      # Invalidating cache should force a re-read.
      people_2 = Set.new(people + %w[peterbald])
      expect(subject).to receive(:graphql_team_data).with(team_identifier).and_return(members: people_2.to_a, team_id: 1234567, roles: Hash[*people_2.collect { |u| [u, "member"] }.flatten])
      expect(logger).to receive(:debug).with("Invalidating cache entry for #{team_dn}")
      expect(logger).to receive(:debug).with("members(#{team_dn}): DN has been marked invalid in cache")
      expect(logger).to receive(:debug).with("Loading GitHub team github.fake:kittensinc/cuddly-kittens")
      subject.invalidate_predictive_cache(entitlement_group_exists)

      # Check that the re-read has occurred and the correct result is achieved.
      expect(subject).not_to receive(:graphql_team_data) # Should already be in object's cache
      team_2 = subject.read_team(entitlement_group_exists)
      expect(team_2.team_id).to eq(1234567)
      expect(team_2.member_strings).to eq(people_2)
    end
  end

  describe "#team_exists?" do
    it "returns true when the team can be read" do

    end

    it "returns false when the team cannot be read" do

    end
  end

  describe "#sync_team" do
    let(:entitlement_group_russian_blues) do
      Entitlements::Models::Group.new(
        dn: "cn=russian-blues,ou=kittensinc,ou=GitHub,dc=github,dc=fake",
        description: ":smile_cat:",
        members: Set.new(%w[blackmanx ragamuffin MAINECOON]),
        metadata: {"team_id" => 1001}
      )
    end

    let(:team_data_old) do
      Entitlements::Backend::GitHubTeam::Models::Team.new(
        team_id: 1001,
        team_name: "russian-blues",
        members: Set.new(%w[blackmanx ragamuffin MAINECOON]),
        ou: "ou=kittensinc,dc=github,dc=com",
        metadata: nil
      )
    end

    let(:team_data_add) do
      Entitlements::Backend::GitHubTeam::Models::Team.new(
        team_id: 1001,
        team_name: "russian-blues",
        members: Set.new(%w[blackmanx HIGhlander RagaMuffin MAINECOON]),
        ou: "ou=kittensinc,dc=github,dc=com",
        metadata: nil
      )
    end

    let(:team_data_remove) do
      Entitlements::Backend::GitHubTeam::Models::Team.new(
        team_id: 1001,
        team_name: "russian-blues",
        members: Set.new(%w[MAINECOON blackmanx]),
        ou: "ou=kittensinc,dc=github,dc=com",
        metadata: nil
      )
    end

    let(:team_data_add_remove) do
      Entitlements::Backend::GitHubTeam::Models::Team.new(
        team_id: 1001,
        team_name: "russian-blues",
        members: Set.new(%w[MAINECOON blackmanx hiGhlander]),
        ou: "ou=kittensinc,dc=github,dc=com",
        metadata: nil
      )
    end

    let(:team_metadata_add) do
      Entitlements::Backend::GitHubTeam::Models::Team.new(
        team_id: 1001,
        team_name: "russian-blues",
        members: Set.new(%w[blackmanx ragamuffin MAINECOON]),
        ou: "ou=kittensinc,dc=github,dc=com",
        metadata: { "parent_team_name" => "cuddly-kittens" }
      )
    end

    let(:team_metadata_add_maintainer) do
      Entitlements::Backend::GitHubTeam::Models::Team.new(
        team_id: 1001,
        team_name: "russian-blues",
        members: Set.new(%w[blackmanx ragamuffin MAINECOON]),
        ou: "ou=kittensinc,dc=github,dc=com",
        metadata: {
          "parent_team_name" => "cuddly-kittens",
          "team_maintainers" => "blackmanx,ragamuffin"
        }
      )
    end
    let(:team_metadata_maintainer_old) do
      Entitlements::Backend::GitHubTeam::Models::Team.new(
        team_id: 1001,
        team_name: "russian-blues",
        members: Set.new(%w[blackmanx ragamuffin MAINECOON]),
        ou: "ou=kittensinc,dc=github,dc=com",
        metadata: {
          "parent_team_name" => "cuddly-kittens",
          "team_maintainers" => "ragamuffin"
        }
      )
    end
    let(:team_metadata_remove_all_maintainers) do
      Entitlements::Backend::GitHubTeam::Models::Team.new(
        team_id: 1001,
        team_name: "russian-blues",
        members: Set.new(%w[blackmanx ragamuffin MAINECOON]),
        ou: "ou=kittensinc,dc=github,dc=com",
        metadata: {
          "parent_team_name" => "cuddly-kittens",
        }
      )
    end
    let(:team_metadata_add_non_member_maintainer) do
      Entitlements::Backend::GitHubTeam::Models::Team.new(
        team_id: 1001,
        team_name: "russian-blues",
        members: Set.new(%w[blackmanx ragamuffin MAINECOON]),
        ou: "ou=kittensinc,dc=github,dc=com",
        metadata: {
          "parent_team_name" => "cuddly-kittens",
          "team_maintainers" => "krukow,ragamuffin"
        }
      )
    end
    let(:team_metadata_remove) do
      Entitlements::Backend::GitHubTeam::Models::Team.new(
        team_id: 1001,
        team_name: "russian-blues",
        members: Set.new(%w[blackmanx ragamuffin MAINECOON]),
        ou: "ou=kittensinc,dc=github,dc=com",
        metadata: nil
      )
    end

    it "returns false when there were no changes to be made" do
      allow(subject).to receive(:read_team).with(team_data_old).and_return(team_data_old)
      expect(logger).to receive(:debug).with(/sync_team\(russian-blues=1001\): Added 0, removed 0/)
      result = subject.sync_team(team_data_old, team_data_old)
      expect(result).to eq(false)
    end

    it "returns true when there were additions" do
      allow(subject).to receive(:read_team).with(team_data_add).and_return(team_data_old)
      expect(subject).to receive(:add_user_to_team).with(user: "highlander", team: team_data_old).and_return(true)
      expect(logger).to receive(:debug).with(/sync_team\(russian-blues=1001\): Added 1, removed 0/)
      result = subject.sync_team(team_data_add, team_data_old)
      expect(result).to eq(true)
    end

    it "returns true when there were removals" do
      allow(subject).to receive(:read_team).with(team_data_remove).and_return(team_data_old)
      expect(subject).to receive(:remove_user_from_team).with(user: "ragamuffin", team: team_data_old).and_return(true)
      expect(logger).to receive(:debug).with(/sync_team\(russian-blues=1001\): Added 0, removed 1/)
      result = subject.sync_team(team_data_remove, team_data_old)
      expect(result).to eq(true)
    end

    it "returns true when there were additions and removals" do
      allow(subject).to receive(:read_team).with(team_data_add_remove).and_return(team_data_old)
      expect(subject).to receive(:add_user_to_team).with(user: "highlander", team: team_data_old).and_return(true)
      expect(subject).to receive(:remove_user_from_team).with(user: "ragamuffin", team: team_data_old).and_return(true)
      expect(logger).to receive(:debug).with(/sync_team\(russian-blues=1001\): Added 1, removed 1/)
      result = subject.sync_team(team_data_add_remove, team_data_old)
      expect(result).to eq(true)
    end

    it "returns false when there were no actual additions and removals" do
      allow(subject).to receive(:read_team).with(team_data_add_remove).and_return(team_data_old)
      expect(subject).to receive(:add_user_to_team).with(user: "highlander", team: team_data_old).and_return(false)
      expect(subject).to receive(:remove_user_from_team).with(user: "ragamuffin", team: team_data_old).and_return(false)
      expect(logger).to receive(:debug).with(/sync_team\(russian-blues=1001\): Added 0, removed 0/)
      result = subject.sync_team(team_data_add_remove, team_data_old)
      expect(result).to eq(false)
    end

    it "returns true when there were metadata changes" do
      allow(subject).to receive(:read_team).with(team_metadata_add).and_return(team_data_old)
      expect(subject).to receive(:team_by_name).with(org_name: "kittensinc", team_name: "cuddly-kittens").and_return({ id: 10 })
      expect(subject).to receive(:update_team).with(team: team_metadata_add, metadata: { parent_team_id: 10 }).and_return(true)
      expect(logger).to receive(:debug).with(/sync_team\(russian-blues=1001\): Parent team change found - From No Parent Team to cuddly-kittens/)
      expect(logger).to receive(:debug).with(/sync_team\(russian-blues=1001\): Added 0, removed 0/)
      result = subject.sync_team(team_metadata_add, team_data_old)
      expect(result).to eq(true)
    end

    it "returns true when there were metadata changes to add maintainer" do
      allow(subject).to receive(:read_team).with(team_metadata_add_maintainer).and_return(team_metadata_maintainer_old)
      expect(logger).to receive(:debug).with(/sync_team\(russian-blues=1001\): Maintainer members change found - From \["ragamuffin"\] to \["blackmanx", \"ragamuffin\"\]/)
      expect(subject).to receive(:add_user_to_team).with(user: "blackmanx", team: team_metadata_maintainer_old, role: "maintainer").and_return(true)
      expect(logger).to receive(:debug).with(/sync_team\(russian-blues=1001\): Added 0, removed 0/)
      result = subject.sync_team(team_metadata_add_maintainer, team_metadata_maintainer_old)
      expect(result).to eq(true)
    end

    it "returns false when there were metadata changes to remove ALL maintainers" do
      allow(subject).to receive(:read_team).with(team_metadata_remove_all_maintainers).and_return(team_metadata_maintainer_old)
      expect(logger).to receive(:debug).with(/sync_team\(russian-blues=1001\): IGNORING GitHub Team Maintainer DELETE/)
      expect(logger).to receive(:debug).with(/sync_team\(russian-blues=1001\): Added 0, removed 0/)
      result = subject.sync_team(team_metadata_remove_all_maintainers, team_metadata_maintainer_old)
      expect(result).to eq(false)
    end

    it "returns true when there were metadata changes to remove a maintainer" do
      allow(subject).to receive(:read_team).with(team_metadata_maintainer_old).and_return(team_metadata_add_maintainer)
      expect(logger).to receive(:debug).with(/sync_team\(russian-blues=1001\): Maintainer members change found - From \["blackmanx", "ragamuffin"\] to \["ragamuffin"\]/)
      expect(subject).to receive(:add_user_to_team).with(user: "blackmanx", team: team_metadata_maintainer_old, role: "member").and_return(true)
      expect(logger).to receive(:debug).with(/sync_team\(russian-blues=1001\): Added 0, removed 0/)
      result = subject.sync_team(team_metadata_maintainer_old, team_metadata_add_maintainer)
      expect(result).to eq(true)
    end

    it "returns false when there were metadata changes to add maintainer who is NOT in the team" do
      allow(subject).to receive(:read_team).with(team_metadata_add_non_member_maintainer).and_return(team_metadata_maintainer_old)
      expect(logger).to receive(:warn).with(/sync_team\(russian-blues=1001\): Maintainers must be a subset of team members. Desired maintainers: \["krukow"\] are not members. Ignoring./)
      expect(logger).to receive(:debug).with(/sync_team\(russian-blues=1001\): Textual change but no semantic change in maintainers. It is remains: \["ragamuffin\"\]./)
      expect(logger).to receive(:debug).with(/sync_team\(russian-blues=1001\): Added 0, removed 0/)
      result = subject.sync_team(team_metadata_add_non_member_maintainer, team_metadata_maintainer_old)
      expect(result).to eq(false)
    end

    # TODO: I'm hard-coding a block for deletes, for now. I'm doing that by making sure we dont set the desired parent_team_id to nil for teams where it is already set
    it "returns false while deletes are prevented" do
      allow(subject).to receive(:read_team).with(team_metadata_add).and_return(team_metadata_remove)
      expect(logger).to receive(:debug).with(/sync_team\(team=russian-blues\): IGNORING GitHub Parent Team DELETE/)
      expect(logger).to receive(:debug).with(/sync_team\(russian-blues=1001\): Added 0, removed 0/)
      result = subject.sync_team(team_metadata_remove, team_metadata_add)
      expect(result).to eq(false)
    end
  end

  describe "#add_user_to_team" do
    let(:team) do
      Entitlements::Backend::GitHubTeam::Models::Team.new(
        team_id: 1001,
        team_name: "russian-blues",
        members: Set.new(%w[blackmanx HIGhlander RagaMuffin MAINECOON]),
        ou: "ou=kittensinc,dc=github,dc=com",
        metadata: {}
      )
    end

    it "returns true when user is added with active membership" do
      expect(subject).to receive(:validate_team_id_and_slug!).with(1001, "russian-blues").and_return(true)
      expect(subject).to receive(:org_members).and_return(Set.new(%w[blackmanx]))

      add_membership_response = {
        "url"   => "https://github.fake/api/v3/teams/1001/memberships/blackmanx",
        "role"  => "member",
        "state" => "active"
      }

      stub_request(:put, "https://github.fake/api/v3/teams/1001/memberships/blackmanx")
        .to_return(
          status: 200,
          body: JSON.generate(add_membership_response),
          headers: {
            "Content-Type" => "application/json"
          }
        )

      result = subject.send(:add_user_to_team, user: "blackmanx", team:)
      expect(result).to eq(true)
    end

    it "returns true when user is added with pending membership" do
      expect(subject).to receive(:validate_team_id_and_slug!).with(1001, "russian-blues").and_return(true)
      expect(subject).to receive(:org_members).and_return(Set.new(%w[blackmanx]))

      add_membership_response = {
        "url"   => "https://github.fake/api/v3/teams/1001/memberships/blackmanx",
        "role"  => "member",
        "state" => "pending"
      }

      stub_request(:put, "https://github.fake/api/v3/teams/1001/memberships/blackmanx")
        .to_return(
          status: 200,
          body: JSON.generate(add_membership_response),
          headers: {
            "Content-Type" => "application/json"
          }
        )

      result = subject.send(:add_user_to_team, user: "blackmanx", team:)
      expect(result).to eq(true)
    end

    it "returns false when something unexpected happens" do
      expect(subject).to receive(:validate_team_id_and_slug!).with(1001, "russian-blues").and_return(true)
      expect(subject).to receive(:org_members).and_return(Set.new(%w[blackmanx]))

      add_membership_response = {
        "url"   => "https://github.fake/api/v3/teams/1001/memberships/blackmanx",
        "role"  => "member",
        "state" => "at chick-fil-a"
      }

      stub_request(:put, "https://github.fake/api/v3/teams/1001/memberships/blackmanx")
        .to_return(
          status: 200,
          body: JSON.generate(add_membership_response),
          headers: {
            "Content-Type" => "application/json"
          }
        )

      result = subject.send(:add_user_to_team, user: "blackmanx", team:)
      expect(result).to eq(false)
    end

    it "returns false when the user is ignored" do
      expect(subject).to receive(:org_members).and_return(Set.new(%w[ragamuffin]))

      result = subject.send(:add_user_to_team, user: "blackmanx", team:)
      expect(result).to eq(false)
    end

    context "ignore_not_found is false" do
      it "raises when user is not found" do
        expect(subject).to receive(:validate_team_id_and_slug!).with(1001, "russian-blues").and_return(true)
        expect(subject).to receive(:org_members).and_return(Set.new(%w[blackmanx]))

        add_membership_response = {
          "url"   => "https://github.fake/api/v3/teams/1001/memberships/blackmanx",
          "role"  => "member",
          "state" => "active"
        }

        stub_request(:put, "https://github.fake/api/v3/teams/1001/memberships/blackmanx")
          .to_return(
            status: 404,
            headers: {
              "Content-Type" => "application/json"
            },
            body: JSON.generate({
              "message"           => "Not Found",
              "documentation_url" => "https://docs.github.com/rest"
            })
          )

        expect { subject.send(:add_user_to_team, user: "blackmanx", team:) }.to raise_error(Octokit::NotFound)
      end
    end

    context "ignore_not_found is true" do
      let(:subject) do
        described_class.new(
          addr: "https://github.fake/api/v3",
          org: "kittensinc",
          token: "GoPackGo",
          ou: "ou=kittensinc,ou=GitHub,dc=github,dc=fake",
          ignore_not_found: true
        )
      end

      it "ignores 404s" do
        expect(subject).to receive(:validate_team_id_and_slug!).with(1001, "russian-blues").and_return(true)
        expect(subject).to receive(:org_members).and_return(Set.new(%w[blackmanx]))

        add_membership_response = {
          "url"   => "https://github.fake/api/v3/teams/1001/memberships/blackmanx",
          "role"  => "member",
          "state" => "active"
        }

        stub_request(:put, "https://github.fake/api/v3/teams/1001/memberships/blackmanx")
          .to_return(
            status: 404,
            headers: {
              "Content-type" => "application/json"
            },
            body: JSON.generate({
              "message"           => "Not Found",
              "documentation_url" => "https://docs.github.com/rest"
            })
          )

        result = subject.send(:add_user_to_team, user: "blackmanx", team:)
        expect(result).to eq(false)
      end
    end
  end

  describe "#remove_user_from_team" do
    let(:team) do
      Entitlements::Backend::GitHubTeam::Models::Team.new(
        team_id: 1001,
        team_name: "russian-blues",
        members: Set.new(%w[blackmanx HIGhlander RagaMuffin MAINECOON]),
        ou: "ou=kittensinc,dc=github,dc=com",
        metadata: {}
      )
    end

    it "returns true when the API returns a 204" do
      stub_request(:delete, "https://github.fake/api/v3/teams/1001/memberships/blackmanx")
        .to_return(status: 204)
      expect(subject).to receive(:validate_team_id_and_slug!).with(1001, "russian-blues").and_return(true)
      expect(subject).to receive(:org_members).and_return(Set.new(%w[blackmanx]))

      result = subject.send(:remove_user_from_team, user: "blackmanx", team:)
      expect(result).to eq(true)
    end

    it "returns false when the user is ignored" do
      expect(subject).to receive(:org_members).and_return(Set.new(%w[ragamuffin]))

      result = subject.send(:remove_user_from_team, user: "blackmanx", team:)
      expect(result).to eq(false)
    end
  end

  describe "#graphql_team_data" do
    context "unhappy paths" do
      it "logs and aborts when receiving a non-200" do
        stub_request(:post, "https://github.fake/api/v3/graphql").to_return(status: 403, body: nil)
        expect(logger).to receive(:fatal).with(/\AAbort due to GraphQL failure on/)
        expect do
          subject.send(:graphql_team_data, "crying-cat-face")
        end.to raise_error(RuntimeError, "GraphQL query failure")
      end

      it "raises a custom exception when team is not found" do
        empty = JSON.generate("data" => { "organization" => { "team" => nil } })
        stub_request(:post, "https://github.fake/api/v3/graphql").to_return(status: 200, body: empty)
        expect do
          subject.send(:graphql_team_data, "crying-cat-face")
        end.to raise_error(Entitlements::Backend::GitHubTeam::Service::TeamNotFound, "Requested team crying-cat-face does not exist in kittensinc!")
      end
    end

    context "team found, single page of results" do
      let(:graphql_dotcom_response) do
        <<-EOF
{"data":{"organization":{"team":{"databaseId":593721,"members":{"edges":[{"node":{"login":"highlander"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHNNS0="},{"node":{"login":"blackmanx"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHNTkI="},{"node":{"login":"toyger"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHOAARtag=="},{"node":{"login":"ocicat"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHOAAVi0w=="},{"node":{"login":"hubot"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHOAAdWqg=="},{"node":{"login":"korat"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHOABODaQ=="},{"node":{"login":"MAINECOON"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHOAEIdJg=="},{"node":{"login":"russianblue"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHOAEqWvg=="},{"node":{"login":"ragamuffin"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHOAHgBJQ=="},{"node":{"login":"minskin"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHOALafPw=="}]}}}}}
        EOF
      end

      it "parses team data from a single page of results" do
        stub_request(:post, "https://github.fake/api/v3/graphql").
          with(
          body: "{\"query\":\"{\\norganization(login: \\\"kittensinc\\\") {\\nteam(slug: \\\"grumpy-cat\\\") {\\ndatabaseId\\nparentTeam {\\nslug\\n}\\nmembers(first: 100, membership: IMMEDIATE) {\\nedges {\\nnode {\\nlogin\\n}\\nrole\\ncursor\\n}\\n}\\n}\\n}\\n}\"}",
          headers: {
            "Authorization" => "bearer GoPackGo",
            "Content-Type"  => "application/json",
          }).to_return(status: 200, body: graphql_dotcom_response)

        result = subject.send(:graphql_team_data, "grumpy-cat")
        members = ["highlander", "blackmanx", "toyger", "ocicat", "hubot", "korat", "mainecoon", "russianblue", "ragamuffin", "minskin"]
        expect(result).to eq(
          members:,
          team_id: 593721,
          parent_team_name: nil,
          roles: Hash[*members.collect { |member| [member, "member"] }.flatten],
        )
      end
    end

    context "team found, multiple pages of results, does not end on edge" do
      before(:each) { allow(subject).to receive(:max_graphql_results).and_return(4) }

      let(:graphql_dotcom_response_1) do
        <<-EOF
{"data":{"organization":{"team":{"databaseId":593721,"members":{"edges":[{"node":{"login":"highlander"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHNNS0="},{"node":{"login":"blackmanx"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHNTkI="},{"node":{"login":"toyger"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHOAARtag=="},{"node":{"login":"ocicat"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHOAAVi0w=="}]}}}}}
        EOF
      end

      let(:graphql_dotcom_response_2) do
        <<-EOF
{"data":{"organization":{"team":{"databaseId":593721,"members":{"edges":[{"node":{"login":"hubot"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHOAAdWqg=="},{"node":{"login":"korat"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHOABODaQ=="},{"node":{"login":"MAINECOON"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHOAEIdJg=="},{"node":{"login":"russianblue"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHOAEqWvg=="}]}}}}}
        EOF
      end

      let(:graphql_dotcom_response_3) do
        <<-EOF
{"data":{"organization":{"team":{"databaseId":593721,"members":{"edges":[{"node":{"login":"ragamuffin"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHOAHgBJQ=="},{"node":{"login":"minskin"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHOALafPw=="}]}}}}}
        EOF
      end

      it "parses team data from paginated results" do
        stub_request(:post, "https://github.fake/api/v3/graphql").
          to_return(
            { status: 200, body: graphql_dotcom_response_1 },
            { status: 200, body: graphql_dotcom_response_2 },
            { status: 200, body: graphql_dotcom_response_3 }
          )

        result = subject.send(:graphql_team_data, "grumpy-cat")
        members = ["highlander", "blackmanx", "toyger", "ocicat", "hubot", "korat", "mainecoon", "russianblue", "ragamuffin", "minskin"]
        expect(result).to eq(
          members:,
          team_id: 593721,
          parent_team_name: nil,
          roles: Hash[*members.collect { |member| [member, "member"] }.flatten],
        )
      end
    end

    context "team found, multiple pages of results, ends on edge" do
      before(:each) { allow(subject).to receive(:max_graphql_results).and_return(5) }

      let(:graphql_dotcom_response_1) do
        <<-EOF
{"data":{"organization":{"team":{"databaseId":593721,"members":{"edges":[{"node":{"login":"highlander"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHNNS0="},{"node":{"login":"blackmanx"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHNTkI="},{"node":{"login":"toyger"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHOAARtag=="},{"node":{"login":"ocicat"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHOAAVi0w=="},{"node":{"login":"hubot"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHOAAdWqg=="}]}}}}}
        EOF
      end

      let(:graphql_dotcom_response_2) do
        <<-EOF
{"data":{"organization":{"team":{"databaseId":593721,"members":{"edges":[{"node":{"login":"korat"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHOABODaQ=="},{"node":{"login":"MAINECOON"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHOAEIdJg=="},{"node":{"login":"russianblue"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHOAEqWvg=="},{"node":{"login":"ragamuffin"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHOAHgBJQ=="},{"node":{"login":"minskin"},"role":"MEMBER","cursor":"Y3Vyc29yOnYyOpHOALafPw=="}]}}}}}
        EOF
      end

      let(:graphql_dotcom_response_3) do
        <<-EOF
{"data":{"organization":{"team":{"databaseId":593721,"members":{"edges":[]}}}}}
        EOF
      end

      it "parses team data from paginated results" do
        stub_request(:post, "https://github.fake/api/v3/graphql").
          to_return(
            { status: 200, body: graphql_dotcom_response_1 },
            { status: 200, body: graphql_dotcom_response_2 },
            { status: 200, body: graphql_dotcom_response_3 }
          )

        result = subject.send(:graphql_team_data, "grumpy-cat")
        members = ["highlander", "blackmanx", "toyger", "ocicat", "hubot", "korat", "mainecoon", "russianblue", "ragamuffin", "minskin"]
        expect(result).to eq(
          members:,
          team_id: 593721,
          parent_team_name: nil,
          roles: Hash[*members.collect { |member| [member, "member"] }.flatten],
        )
      end
    end
  end

  describe "#validate_team_id_and_slug!" do
    let(:octokit) { instance_double(Octokit::Client) }

    it "returns without error if the team ID matches the slug" do
      allow(subject).to receive(:octokit).and_return(octokit)
      expect(octokit).to receive(:team).with(1234).and_return(slug: "my-slug")

      expect do
        subject.send(:validate_team_id_and_slug!, 1234, "my-slug")
      end.not_to raise_error
    end

    it "raises a validation error if there is no match" do
      allow(subject).to receive(:octokit).and_return(octokit)
      expect(octokit).to receive(:team).with(1234).and_return(slug: "some-other-slug")

      expect do
        subject.send(:validate_team_id_and_slug!, 1234, "my-slug")
      end.to raise_error(RuntimeError, 'validate_team_id_and_slug! mismatch: team_id=1234 expected="my-slug" got="some-other-slug"')
    end

    it "does not handle octokit error" do
      exc = StandardError.new("Whoops!")
      allow(subject).to receive(:octokit).and_return(octokit)
      expect(octokit).to receive(:team).with(1234).and_raise(exc)

      expect do
        subject.send(:validate_team_id_and_slug!, 1234, "my-slug")
      end.to raise_error(exc)
    end
  end

  describe "#create_team" do
    let(:octokit) { instance_double(Octokit::Client) }

    it "creates a team" do
      octokit = instance_double(Octokit::Client)
      allow(subject).to receive(:octokit).and_return(octokit)
      expect(octokit).to receive(:create_team).and_return(true)
      expect(logger).to receive(:debug).with("create_team(team=cuddly-kittens)")

      created = subject.create_team(entitlement_group: entitlement_group_exists)
      expect(created).to eq(true)
    end

    it "creates a team with a parent team" do
      octokit = instance_double(Octokit::Client)
      allow(subject).to receive(:octokit).and_return(octokit)
      expect(octokit).to receive(:create_team).and_return(true)
      expect(subject).to receive(:graphql_team_data).with("parent-cats").and_return(members: Set.new, team_id: 1234567)
      expect(logger).to receive(:debug).with("create_team(team=cuddly-kittens) Parent team parent-cats with id 1234567 found")
      expect(logger).to receive(:debug).with("create_team(team=cuddly-kittens)")

      created = subject.create_team(entitlement_group: entitlement_group_parent_team)
      expect(created).to eq(true)
    end

    it "creates a team with empty metadata" do
      octokit = instance_double(Octokit::Client)
      allow(subject).to receive(:octokit).and_return(octokit)
      expect(octokit).to receive(:create_team).and_return(true)
      expect(logger).to receive(:debug).with("create_team(team=cuddly-kittens) No metadata found")
      expect(logger).to receive(:debug).with("create_team(team=cuddly-kittens)")

      created = subject.create_team(entitlement_group: entitlement_group_exists_no_metadata)
      expect(created).to eq(true)
    end

    it "fails to create a team which already exists" do
      octokit = instance_double(Octokit::Client)
      allow(subject).to receive(:octokit).and_return(octokit)
      expect(octokit).to receive(:create_team).and_raise(Octokit::UnprocessableEntity)
      expect(logger).to receive(:debug).with("create_team(team=cuddly-kittens)")
      expect(logger).to receive(:debug).with("create_team(team=cuddly-kittens) ERROR - Octokit::UnprocessableEntity")

      created = subject.create_team(entitlement_group: entitlement_group_exists)
      expect(created).to eq(false)
    end
  end

  describe "#update_team" do
    let(:octokit) { instance_double(Octokit::Client) }

    let(:team_data) do
      Entitlements::Backend::GitHubTeam::Models::Team.new(
        team_id: 123,
        team_name: "mainecoon",
        members: Set.new,
        ou: "ou=kittensinc,dc=github,dc=com",
        metadata: nil
      )
    end

    let(:team_data_new) do
      Entitlements::Backend::GitHubTeam::Models::Team.new(
        team_id: -999,
        team_name: "mainecoon",
        members: Set.new,
        ou: "ou=kittensinc,dc=github,dc=com",
        metadata: nil
      )
    end

    let(:team_data_parent) do
      Entitlements::Backend::GitHubTeam::Models::Team.new(
        team_id: 123,
        team_name: "mainecoon",
        members: Set.new,
        ou: "ou=kittensinc,dc=github,dc=com",
        metadata: { "parent_team_name" => "parent-cats" }
      )
    end

    it "updates a team" do
      octokit = instance_double(Octokit::Client)
      allow(subject).to receive(:octokit).and_return(octokit)
      expect(octokit).to receive(:update_team).and_return(true)
      expect(logger).to receive(:debug).with("update_team(team=mainecoon)")

      created = subject.update_team(team: team_data)
      expect(created).to eq(true)
    end

    it "fails to update a team which already exists" do
      octokit = instance_double(Octokit::Client)
      allow(subject).to receive(:octokit).and_return(octokit)
      expect(octokit).to receive(:update_team).and_raise(Octokit::UnprocessableEntity)
      expect(logger).to receive(:debug).with("update_team(team=mainecoon)")
      expect(logger).to receive(:debug).with("update_team(team=mainecoon) ERROR - Octokit::UnprocessableEntity")

      created = subject.update_team(team: team_data_new)
      expect(created).to eq(false)
    end
  end

  describe "#team_by_name" do
    let(:octokit) { instance_double(Octokit::Client) }

    let(:team_data) do
      {
        id: 10,
        slug: "mainecoon"
      }
    end

    it "gets a team by name" do
      team_object = instance_double(Sawyer::Resource)
      octokit = instance_double(Octokit::Client)
      allow(subject).to receive(:octokit).and_return(octokit)
      expect(octokit).to receive(:team_by_name).and_return(team_object)

      team = subject.team_by_name(org_name: "kittensinc", team_name: "cuddly-kittens")
      expect(team).to eq(team_object)
    end
  end
end
