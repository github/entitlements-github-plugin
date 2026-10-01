# frozen_string_literal: true

require_relative "../../spec_helper"
require "tmpdir"
require "fileutils"

describe Entitlements::Backend::GitHubRepository do
  let(:backend) { described_class }
  let(:base) { "ou=repositories,dc=example,dc=com" }
  let(:config) do
    { "dir" => fixture("repositories"), "base" => base, "org" => "example", "token" => "test-token" }
  end
  let(:service) { backend::Service.new(org: "example", token: "test-token", ou: base) }
  let(:members) { { "alice" => "member", "bob" => "member", "carol" => "member", "owner" => "admin" } }

  def access(roles = {}, repository: "app", teams: [], organization_access: nil, **inline_roles)
    backend::Models::RepositoryAccess.new(repository: repository, roles: roles.merge(inline_roles), teams: teams,
      organization_access: organization_access || self.organization_access, ou: base)
  end

  def team(id = 1, slug = "engineering", parent_id = nil, source = "direct")
    { id: id, slug: slug, parent_id: parent_id, access_source: source }
  end

  def stub_teams(teams = [], endpoint: "https://api.github.com/repos/example/app/teams")
    teams = teams.map { |entry| { access_source: "direct", type: "organization" }.merge(entry) }
    stub_request(:get, endpoint).with(query: { per_page: 100 })
      .to_return(status: 200, body: JSON.generate(teams), headers: { "Content-Type" => "application/json" })
  end

  def organization_access(base_role: "none", assignments: {}, membership: members)
    backend::Models::OrganizationAccess.new(members: membership, base_role: base_role, assignments: assignments)
  end

  def organization_role(id = 10, base_role = "write", name = "all_repo_write")
    { id: id, name: name, base_role: base_role, permissions: [] }
  end

  before do
    stub_teams
  end

  def collaborator(login, role = "write")
    { login: login, role_name: role, permissions: {} }
  end

  def stub_collaborators(collaborators = [], endpoint: "https://api.github.com/repos/example/app/collaborators")
    stub_request(:get, endpoint).with(query: { affiliation: "direct", per_page: 100 })
      .to_return(status: 200, body: JSON.generate(collaborators), headers: { "Content-Type" => "application/json" })
  end

  describe "method contracts" do
    it "requires String configuration keys and a Hash of configuration data" do
      expect { backend::Configuration.new([]) }.to raise_error(ParamContractError)
      expect { backend::Configuration.validate!(:repos, config) }.to raise_error(ParamContractError)
      expect { backend::Configuration.validate!("repos", []) }.to raise_error(ParamContractError)
      expect { backend::Controller.new(:repos, config) }.to raise_error(ParamContractError)
    end

    it "requires String user logins and roles in access models" do
      expect { access(7 => "read") }.to raise_error(ParamContractError)
      expect { access("alice" => 7) }.to raise_error(ParamContractError)
      expect { organization_access(membership: { 7 => "member" }) }.to raise_error(ParamContractError)
      expect { organization_access(membership: { "alice" => 7 }) }.to raise_error(ParamContractError)
      expect { organization_access(assignments: { "alice" => "write" }) }.to raise_error(ParamContractError)
    end

    it "requires String logins for access lookups without restricting their format" do
      model = access("../alice" => "write")
      expect(model.role_for("../alice")).to eq("write")
      expect { model.role_for(nil) }.to raise_error(ParamContractError)
      expect { model.login_for(7) }.to raise_error(ParamContractError)
      context = organization_access
      expect { context.owner?(nil) }.to raise_error(ParamContractError)
      expect { context.inherited_role(7) }.to raise_error(ParamContractError)
      expect { context.sources(:alice) }.to raise_error(ParamContractError)
    end

    it "allows omitted optional model keywords but rejects invalid supplied values" do
      model = backend::Models::RepositoryAccess.new(repository: "app", roles: {}, ou: base)
      expect(model.teams).to eq({})
      expect(model.organization_access).to be_nil
      expect { access(teams: nil) }.to raise_error(ParamContractError)
      expect { access(organization_access: {}) }.to raise_error(ParamContractError)
    end

    it "requires typed service arguments before requesting GitHub" do
      expect { service.read_repository(nil) }.to raise_error(ParamContractError)
      expect { service.read_repository("app", refresh: nil) }.to raise_error(ParamContractError)
      expect { service.sync_repository("app", {}) }.to raise_error(ParamContractError)
      expect { service.sync_repository("app", ["remove"]) }.to raise_error(ParamContractError)
    end

    it "requires repository models and action objects at provider and controller boundaries" do
      provider = backend::Provider.new(config: config)
      expect { provider.diff({}, "repos") }.to raise_error(ParamContractError)
      expect { provider.diff(access, :repos) }.to raise_error(ParamContractError)
      expect { provider.commit({}) }.to raise_error(ParamContractError)
      expect { backend::Controller.new("repos", config).apply({}) }.to raise_error(ParamContractError)
    end
  end

  describe "configuration validation" do
    it "registers and loads a minimal backend without requesting GitHub" do
      expect(backend::Controller.identifier).to eq("github_repository")
      expect(backend::Controller.priority).to eq(50)
      expect(backend::Controller.new("repos", config).actions).to eq([])
    end

    %w[dir base org token].each do |key|
      it "requires a nonempty #{key}" do
        expect { backend::Controller.new("repos", config.reject { |k, _| k == key }) }.to raise_error(RuntimeError, /missing attribute/)
        expect { backend::Controller.new("repos", config.merge(key => " ")) }.to raise_error(backend::Error, /must not be empty/)
      end
    end

    [
      ["features", ["invite"]], ["features", nil], ["ignore", "alice"], ["allowed_types", ["json"]],
      ["allowed_methods", ["unknown"]], ["ignore_not_found", "yes"], ["token", 1],
      ["addr", "ftp://github.test"], ["addr", "https://user:pass@github.test"],
      ["addr", "https://github.test?query=yes"], ["addr", "not a url"]
    ].each do |key, value|
      it "rejects #{key}=#{value.inspect}" do
        expect { backend::Controller.new("repos", config.merge(key => value)) }.to raise_error(RuntimeError)
      end
    end

    it "accepts nil and valid enterprise addresses, flags, and managed-user logins" do
      [nil, "https://github.test/api/v3/"].each do |addr|
        expect { backend::Controller.new("repos", config.merge("addr" => addr, "features" => [],
          "ignore" => ["alice_enterprise"], "allowed_methods" => %w[username group]))
        }.not_to raise_error
      end
    end

    it "does not validate organization or ignored login formats" do
      expect { backend::Configuration.validate!("repos", config.merge("org" => "bad/org", "ignore" => ["../alice"])) }
        .not_to raise_error
    end
  end

  describe "repository model" do
    it "compares roles and names case insensitively, preserving display logins and sorted keys" do
      model = access("Bob" => "maintain", "ALIce" => "read")
      expect(model.roles.keys).to eq(%w[alice bob])
      expect(model.role_for("ALICE")).to eq("read")
      expect(model.login_for("alice")).to eq("ALIce")
      expect(model.member?("bOB")).to be(true)
      expect(model.member_strings).to eq(Set.new(%w[Bob ALIce]))
      expect(model).to eq(access({ "alice" => "read", "bob" => "maintain" }, repository: "APP"))
      expect(model == access("alice" => "write", "bob" => "maintain")).to be(false)
      expect(model == access({ "alice" => "read", "bob" => "maintain" }, repository: "other")).to be(false)
      expect(model == :none).to be(false)
    end

    describe "organization access model" do
      it "combines base permissions, ownership and arbitrary assigned roles without matching names" do
        role = organization_role(10, "maintain", "enterprise-defined-role")
        context = organization_access(base_role: "read", assignments: { "ALICE" => [role] })
        expect(context.inherited_role("alice")).to eq("maintain")
        expect(context.inherited_role("bob")).to eq("read")
        expect(context.inherited_role("owner")).to eq("admin")
        expect(context.inherited_role("outsider")).to be_nil
        expect(context.sources("ALICE")).to include('organization role "enterprise-defined-role"', "organization base read")
        expect(context.sources("owner")).to include("organization ownership")
        expect(context).to eq(organization_access(base_role: "read", assignments: { "alice" => [role] }))
        expect(context).not_to eq(organization_access)
        expect(context).not_to eq(nil)
        expect(organization_access.inherited_role("alice")).to be_nil
      end

      it "rejects unavailable base settings or unsupported organization membership roles" do
        [nil, "custom"].each do |role|
          expect { organization_access(base_role: role) }.to raise_error(backend::Error, /Malformed organization access/)
        end
        expect { organization_access(membership: { "alice" => "unknown" }) }.to raise_error(backend::Error)
      end
    end

    it "requires a String repository name" do
      expect { access({}, repository: nil) }.to raise_error(ParamContractError)
    end

    it "rejects custom roles and duplicate case variants" do
      expect { access("alice" => "custom") }.to raise_error(backend::Error, /Unsupported/)
      expect { access("alice" => "read", "ALICE" => "write") }.to raise_error(backend::Error, /Duplicate/)
    end

    it "does not validate login formats" do
      expect(access("../alice" => "write").role_for("../alice")).to eq("write")
    end

    it "tracks teams separately from users and orders parents before children" do
      model = access("engineering" => "read", :teams => [team(2, "child", 1), team])
      expect(model.member_strings).to eq(Set.new(["engineering"]))
      expect(model.ordered_teams.map { |entry| entry[:id] }).to eq([1, 2])
      expect(model).not_to eq(access("engineering" => "read"))
      [team(nil), team(0), team(1, "../bad"), team(1, "valid", -1)].each do |invalid|
        expect { access(teams: [invalid]) }.to raise_error(backend::Error, /Malformed/)
      end
      expect { access(teams: [team, team]) }.to raise_error(backend::Error, /Duplicate/)
      expect { access(teams: [team, team(2, "ENGINEERING")]) }.to raise_error(backend::Error, /Duplicate/)
      expect { access(teams: [team(1, "one", 2), team(2, "two", 1)]) }.to raise_error(backend::Error, /Cyclic/)
    end
  end

  describe "recursive loader" do
    before do
      cache[:people_obj] = Entitlements::Data::People::YAML.new(filename: fixture("people.yaml"))
      cache[:file_objects] = {}
    end

    it "evaluates text, YAML, Ruby, group references and expiration deterministically" do
      result = backend::Configuration.new(config).load
      expect(result.map(&:repository)).to eq(["entitlements-app", "other.repo"])
      expect(result.first.roles).to eq("balinese" => "read", "chartreux" => "triage", "dwelf" => "write")
      expect(result.last.roles.values.uniq).to eq(["maintain"])
      expect(result.last.roles).not_to have_key("bengal")
    end

    it "applies standard filters" do
      filter = Class.new do
        def initialize(**); end

        def filtered?(person)
          person.uid.downcase == "balinese"
        end
      end
      Entitlements::Data::Groups::Calculated.register_filter("exclude", { class: filter, config: {} })
      expect(backend::Configuration.new(config).load.first.roles).not_to have_key("balinese")
    end

    it "resolves a relative dir against the configuration root" do
      expect(backend::Configuration.new(config.merge("dir" => "../repositories")).load.size).to eq(2)
    end

    it "rejects a disallowed extension" do
      expect { backend::Configuration.new(config.merge("allowed_types" => ["txt"])).load }.to raise_error(backend::Error, /role file/)
    end

    it "honors allowed rule methods" do
      expect { backend::Configuration.new(config.merge("allowed_methods" => ["group"])).load }.to raise_error(RuntimeError, /not a valid function/)
    end

    it "fails when the configured root is absent" do
      expect { backend::Configuration.new(config.merge("dir" => fixture("missing-repositories"))).load }.to raise_error(Errno::ENOENT)
    end

    it "treats an empty repository directory as empty desired access and a deleted directory as unmanaged" do
      Dir.mktmpdir do |root|
        Dir.mkdir("#{root}/app")
        loader = backend::Configuration.new(config.merge("dir" => root))
        expect(loader.load.first.roles).to eq({})
        Dir.rmdir("#{root}/app")
        expect(loader.load).to eq([])
      end
    end

    ["README.md", "custom.txt", "write.json", "write", ".hidden", "write.txt/nested.txt"].each do |entry|
      it "rejects unexpected role entry #{entry}" do
        Dir.mktmpdir do |root|
          FileUtils.mkdir_p(File.dirname("#{root}/app/#{entry}"))
          File.write("#{root}/app/#{entry}", "username = balinese\n")
          expect { backend::Configuration.new(config.merge("dir" => root)).load }.to raise_error(backend::Error, /role file/)
        end
      end
    end

    it "rejects root files, symlinks, duplicate role files and duplicate users" do
      Dir.mktmpdir do |root|
        loader = backend::Configuration.new(config.merge("dir" => root))
        File.write("#{root}/README", "")
        expect { loader.load }.to raise_error(backend::Error, /directory/)
        File.unlink("#{root}/README")
        File.symlink(config.fetch("dir"), "#{root}/app")
        expect { loader.load }.to raise_error(backend::Error, /directory/)
        File.unlink("#{root}/app")
        Dir.mkdir("#{root}/app")
        File.symlink("#{config.fetch('dir')}/entitlements-app/read.txt", "#{root}/app/read.txt")
        expect { loader.load }.to raise_error(backend::Error, /role file/)
        File.unlink("#{root}/app/read.txt")
        File.write("#{root}/app/read.txt", "username = balinese\n")
        File.write("#{root}/app/read.yaml", "rules:\n  username: bengal\n")
        expect { loader.load }.to raise_error(backend::Error, /role file/)
        File.rename("#{root}/app/read.yaml", "#{root}/app/write.yaml")
        File.write("#{root}/app/write.yaml", "rules:\n  username: BALINESE\n")
        expect { loader.load }.to raise_error(backend::Error, /duplicate user/)
      end
    end
  end

  describe "diff and controller" do
    let(:provider) { backend::Provider.new(config: config) }
    before do
      allow(backend::Service).to receive(:new).and_return(service)
      allow(service).to receive(:active_members).and_return(members)
    end

    described_class::FEATURES.length.succ.times.flat_map { |size| described_class::FEATURES.combination(size).to_a }.each do |features|
      it "honors feature combination #{features.inspect} in instructions and displayed state" do
        config["features"] = features
        allow(service).to receive(:read_repository).with("app").and_return(access({ "alice" => "read", "bob" => "write" }, teams: [team]))
        action = provider.diff(access("ALICE" => "admin", "carol" => "triage"), "repos")
        if features.empty?
          expect(action).to be_nil
        else
          expected = []
          expected << { action: :upsert, login: "ALICE", permission: "admin" } if features.include?("update")
          expected << { action: :upsert, login: "carol", permission: "triage" } if features.include?("add")
          expected << { action: :remove, login: "bob" } if features.include?("remove")
          expected << { action: :remove_team, team_id: 1, slug: "engineering" } if features.include?("remove")
          expect(action.implementation).to eq(expected)
          effective = { "alice" => features.include?("update") ? "admin" : "read" }
          effective["carol"] = "triage" if features.include?("add")
          effective["bob"] = "write" unless features.include?("remove")
          expect(action.updated.roles).to eq(effective)
          expect(action.updated.teams.empty?).to eq(features.include?("remove"))
          expect(action.existing == action.updated).to be(false)
        end
      end
    end

    it "ignores configured users on both sides and handles case-only changes as no-op" do
      config["ignore"] = ["OWNER", "Bob"]
      allow(service).to receive(:read_repository).and_return(access("alice" => "read", "bob" => "admin"))
      expect(provider.diff(access("ALICE" => "read", "owner" => "write"), "repos")).to be_nil
    end

    it "rejects desired non-members before reading a repository" do
      expect(service).not_to receive(:read_repository)
      expect { provider.diff(access("outsider" => "read"), "repos") }.to raise_error(backend::Error, /not active/)
    end

    it "warns and ignores non-members when explicitly configured" do
      config["ignore_not_found"] = true
      expect(logger).to receive(:warn).with(/outsider.*ignored/)
      allow(service).to receive(:read_repository).and_return(access)
      expect(provider.diff(access("outsider" => "read"), "repos")).to be_nil
    end

    it "validates all files before API requests, calculates and applies one action per repository" do
      desired = access("alice" => "maintain")
      loader = instance_double(backend::Configuration, load: [desired])
      allow(backend::Configuration).to receive(:new).and_return(loader)
      allow(service).to receive(:read_repository).and_return(access("alice" => "write"))
      controller = backend::Controller.new("repos", config)
      actions = controller.calculate
      expect(actions.size).to eq(1)
      expect(controller.change_count).to eq(1)
      expect(service).to receive(:sync_repository)
        .with("app", [{ action: :upsert, login: "alice", permission: "maintain" }], teams: [])
      controller.apply(actions.first)
      allow(loader).to receive(:load).and_raise(backend::Error, "invalid file")
      expect(service).not_to receive(:read_repository)
      expect { controller.calculate }.to raise_error(backend::Error, /invalid file/)
    end

    it "does not calculate destructive cleanup for removed repository directories" do
      Dir.mktmpdir do |root|
        expect(service).not_to receive(:read_repository)
        expect(backend::Controller.new("repos", config.merge("dir" => root)).calculate).to eq([])
      end
    end

    it "rejects invalid actions" do
      action = Entitlements::Models::Action.new("app", access, nil, "repos")
      expect { provider.commit(action) }.to raise_error(backend::Error, /Invalid repository action/)
    end

    it "rejects observed state without organization access metadata" do
      missing = backend::Models::RepositoryAccess.new(repository: "app", roles: {}, ou: base)
      allow(service).to receive(:read_repository).and_return(missing)
      expect { provider.diff(access, "repos") }.to raise_error(backend::Error, /Missing organization access snapshot/)
    end

    it "calculates and counts team-only actions without pretending teams are users" do
      desired = access
      allow(backend::Configuration).to receive(:new).and_return(instance_double(backend::Configuration, load: [desired]))
      allow(service).to receive(:read_repository).and_return(access(teams: [team]))
      controller = backend::Controller.new("repos", config)
      action = controller.calculate.first
      expect(controller.change_count).to eq(1)
      expect(action.implementation).to eq([{ action: :remove_team, team_id: 1, slug: "engineering" }])
      expect(action.existing.member_strings).to be_empty
      expect(action.updated.teams).to be_empty
      expect(action.existing).not_to eq(action.updated)
    end

    it "preserves teams when remove is disabled and warns about the unenforced policy" do
      config["features"] = %w[add update]
      allow(service).to receive(:read_repository).and_return(access(teams: [team]))
      expect(logger).to receive(:warn).with(/individual-only.*not enforced/)
      action = provider.diff(access("alice" => "read"), "repos")
      expect(action.updated.teams).to eq(action.existing.teams)
      expect(action.implementation.map { |instruction| instruction[:action] }).to eq([:upsert])
    end

    it "removes undeclared outside direct grants as well as all direct teams" do
      allow(service).to receive(:read_repository).and_return(access("outsider" => "read", :teams => [team]))
      action = provider.diff(access("alice" => "read"), "repos")
      expect(action.implementation.map { |instruction| instruction[:action] }).to eq([:upsert, :remove, :remove_team])
      expect(action.updated.roles).to eq("alice" => "read")
    end

    it "rejects stale plans before mutation and applies against the preflight team snapshot" do
      allow(service).to receive(:read_repository).and_return(access(teams: [team]))
      action = provider.diff(access, "repos")
      allow(service).to receive(:read_repository).with("app", refresh: true).and_return(access)
      expect(service).not_to receive(:sync_repository)
      expect { provider.commit(action) }.to raise_error(backend::Error, /changed since calculation/)
      RSpec::Mocks.space.proxy_for(service).reset
      allow(service).to receive(:read_repository).with("app", refresh: true).and_return(action.existing)
      expect(service).to receive(:sync_repository).with("app", action.implementation, teams: action.existing.teams.values)
      provider.commit(action)
    end

    it "accepts desired owners without ignore_not_found and defers their ambiguous direct grants" do
      allow(service).to receive(:read_repository).and_return(access(teams: [team], organization_access: organization_access))
      expect(logger).to receive(:warn).with(/DEFER app: owner.*inherited admin.*organization ownership/)
      action = provider.diff(access("owner" => "read"), "repos")
      expect(action.implementation).to eq([{ action: :remove_team, team_id: 1, slug: "engineering" }])
      expect(action.ignored_users).to be_empty
    end

    described_class::ROLES.each_key do |role|
      it "handles all-repository #{role} assignments and provisions equal direct grants" do
        inherited = organization_access(assignments: { "alice" => [organization_role(10, role, "arbitrary-#{role}")] })
        allow(service).to receive(:read_repository).and_return(access(organization_access: inherited))
        action = provider.diff(access("alice" => role), "repos")
        expect(action.implementation).to eq([{ action: :upsert, login: "alice", permission: backend::ROLES.fetch(role) }])
      end
    end

    it "defers lower desired roles without inventing a successful direct grant or raising inherited privileges" do
      inherited = organization_access(assignments: { "alice" => [organization_role] })
      current = access({ "alice" => "admin" }, teams: [team], organization_access: inherited)
      allow(service).to receive(:read_repository).and_return(current)
      expect(logger).to receive(:warn).with(/DEFER app: alice direct role read; inherited write/)
      action = provider.diff(access("alice" => "read"), "repos")
      expect(action.updated.roles).to eq("alice" => "admin")
      expect(action.implementation.map { |entry| entry[:action] }).to eq([:remove_team])
    end

    it "defers roles below organization base and continues to provision users above the base" do
      allow(service).to receive(:read_repository).and_return(access(organization_access: organization_access(base_role: "write")))
      expect(logger).to receive(:warn).with(/DEFER app: alice.*organization base write/)
      action = provider.diff(access("alice" => "read", "bob" => "admin"), "repos")
      expect(action.updated.roles).to eq("bob" => "admin")
    end

    it "removes undeclared direct grants even when a non-owner retains organization-wide access" do
      inherited = organization_access(assignments: { "alice" => [organization_role] })
      allow(service).to receive(:read_repository).and_return(access({ "alice" => "admin" }, organization_access: inherited))
      action = provider.diff(access, "repos")
      expect(action.implementation).to eq([{ action: :remove, login: "alice" }])
    end

    it "preserves organization and enterprise team sources while removing a direct association" do
      teams = [team, team(2, "security", nil, "organization"), team(3, "enterprise", nil, "enterprise")]
      allow(service).to receive(:read_repository).and_return(access(teams: teams, organization_access: organization_access))
      action = provider.diff(access, "repos")
      expect(action.implementation).to eq([{ action: :remove_team, team_id: 1, slug: "engineering" }])
      expect(action.updated.teams.keys).to eq([2, 3])
      # A direct association can mask an organization-wide source for the same team.
      expect(action.updated).to eq(access(teams: teams.map { |entry| entry.merge(access_source: "organization") },
        organization_access: organization_access))
    end

    it "plans a direct grant from the organization snapshot after owner JIT expires" do
      demoted = organization_access(membership: members.merge("owner" => "member"))
      allow(service).to receive(:read_repository).and_return(access(organization_access: demoted))
      action = provider.diff(access("owner" => "read"), "repos")
      expect(action.implementation).to eq([{ action: :upsert, login: "owner", permission: "pull" }])
    end
  end

  describe "end-to-end reconciliation" do
    it "converges to individual-only grants, removing teams and undeclared direct grants" do
      cache[:people_obj] = Entitlements::Data::People::YAML.new(filename: fixture("people.yaml"))
      cache[:file_objects] = {}
      cache[:github_org_members] = {
        "|example" => { cache: true, value: members.merge("balinese" => "member") },
      }
      stub_request(:get, "https://api.github.com/repos/example/app/collaborators")
        .with(query: { affiliation: "direct", per_page: 100 }).to_return(
          { status: 200, body: JSON.generate([collaborator("balinese", "read"), collaborator("bob"), collaborator("outsider")]),
            headers: { "Content-Type" => "application/json" } },
          { status: 200, body: JSON.generate([collaborator("balinese", "read"), collaborator("bob"), collaborator("outsider")]),
            headers: { "Content-Type" => "application/json" } },
          { status: 200, body: JSON.generate([collaborator("balinese", "write")]),
            headers: { "Content-Type" => "application/json" } }
      )
      stub_teams([{ id: 1, slug: "engineering", parent: nil }])
      put = stub_request(:put, "https://api.github.com/repos/example/app/collaborators/balinese")
        .with(body: { permission: "push" }).to_return(status: 204)
      delete = stub_request(:delete, "https://api.github.com/repos/example/app/collaborators/bob").to_return(status: 204)
      %w[outsider].each do |login|
        stub_request(:delete, "https://api.github.com/repos/example/app/collaborators/#{login}").to_return(status: 204)
      end
      remove_team = stub_request(:delete, "https://api.github.com/orgs/example/teams/engineering/repos/example/app").to_return do
        stub_teams
        { status: 204 }
      end
      Dir.mktmpdir do |root|
        Dir.mkdir("#{root}/app")
        File.write("#{root}/app/write.txt", "username = balinese\n")
        controller = backend::Controller.new("repos", config.merge("dir" => root))
        actions = controller.calculate
        expect(actions.size).to eq(1)
        expect(actions.first.implementation.size).to eq(4)
        controller.apply(actions.first)
        expect(controller.calculate).to eq([])
      end
      expect(put).to have_been_requested.once
      expect(delete).to have_been_requested.once
      expect(remove_team).to have_been_requested.once
      expect(a_request(:get, %r{\Ahttps://api\.github\.com/orgs/example(?:/members|/organization-roles)?\z}))
        .not_to have_been_made
      expect(a_request(:delete, "https://api.github.com/repos/example/app/collaborators/carol")).not_to have_been_made
      expect(a_request(:delete, "https://api.github.com/repos/example/app/collaborators/owner")).not_to have_been_made
    end
  end

  describe "GitHub transport" do
    before do
      allow(service).to receive(:org_members).and_return(members)
    end

    it "uses the shared organization membership snapshot and accepts owners" do
      expect(service).to receive(:org_members).once.and_return(members)
      expect(service.active_members).to eq(members)
      expect(service.organization_access.owner?("owner")).to be(true)
    end

    it "does not read organization settings or role assignments" do
      context = service.organization_access
      expect(context.base_role).to eq("none")
      expect(context.assignments).to be_empty
      expect(a_request(:get, "https://api.github.com/orgs/example")).not_to have_been_made
      expect(a_request(:get, %r{/orgs/example/organization-roles})).not_to have_been_made
    end

    it "wraps organization membership transport failures" do
      allow(service).to receive(:org_members).and_call_original
      stub_request(:get, "https://api.github.com/orgs/example/members")
        .with(query: { role: "admin", per_page: 100 })
        .to_return(status: 403, body: '{"message":"denied"}', headers: { "Content-Type" => "application/json" })
      expect { service.organization_access }.to raise_error(backend::Error, /Reading organization membership/)
    end

    it "does not treat organization owners as direct collaborators" do
      stub_collaborators
      expect(service.read_repository("app").roles).to be_empty
    end

    it "rejects owner mutations even if an invalid instruction bypassed the planner" do
      [:upsert, :remove].each do |action|
        expect { service.sync_repository("app", [{ action: action, login: "owner", permission: "pull" }]) }
          .to raise_error(backend::Error, /owner.*deferred/)
      end
      expect(a_request(:put, /collaborators/)).not_to have_been_made
      expect(a_request(:delete, /collaborators/)).not_to have_been_made
    end

    it "preserves enterprise team access alongside direct user grants" do
      stub_collaborators([collaborator("alice", "read")])
      stub_teams([{ id: 9, slug: "enterprise", parent: nil, type: "enterprise", access_source: "enterprise" }])
      snapshot = service.read_repository("app")
      expect(snapshot.roles).to eq("alice" => "read")
      expect(snapshot.direct_teams).to be_empty
    end

    it "rejects team lists without source metadata instead of guessing that grants are direct" do
      stub_collaborators
      stub_teams([{ id: 1, slug: "team", parent: nil, access_source: nil }])
      expect { service.read_repository("app") }.to raise_error(backend::Error, /access_source/)
      stub_teams([{ id: 1, slug: "team", parent: nil, type: "enterprise" }])
      expect { service.read_repository("app") }.to raise_error(backend::Error, /access_source/)
    end

    it "refuses to delete a team whose source became organization-wide" do
      stub_teams([{ id: 1, slug: "team", parent: nil, access_source: "organization" }])
      expect { service.sync_repository("app", [{ action: :remove_team, team_id: 1, slug: "team" }]) }
        .to raise_error(backend::Error, /access source changed/)
      expect(a_request(:delete, /teams/)).not_to have_been_made
    end

    it "paginates direct collaborators and caches per repository" do
      request = stub_request(:get, "https://api.github.com/repos/example/app/collaborators")
        .with(query: { affiliation: "direct", per_page: 100 })
        .to_return(status: 200, body: JSON.generate([collaborator("Alice", "Read"), collaborator("outsider")]),
          headers: { "Content-Type" => "application/json",
                     "Link" => '<https://api.github.com/repos/example/app/collaborators?affiliation=direct&page=2&per_page=100>; rel="next"' })
      second = stub_request(:get, "https://api.github.com/repos/example/app/collaborators")
        .with(query: { affiliation: "direct", page: 2, per_page: 100 })
        .to_return(status: 200, body: JSON.generate([collaborator("Carol", "maintain")]),
          headers: { "Content-Type" => "application/json" })
      expect(service.read_repository("app").roles).to eq("alice" => "read", "carol" => "maintain", "outsider" => "write")
      expect(service.read_repository("APP").roles).to eq("alice" => "read", "carol" => "maintain", "outsider" => "write")
      expect(request).to have_been_requested.once
      expect(second).to have_been_requested.once
    end

    it "uses the role returned by the direct collaborator inventory" do
      stub_collaborators([collaborator("alice", "triage")])
      expect(service.read_repository("app").roles).to eq("alice" => "triage")
    end

    described_class::ROLES.each_key do |role|
      it "reads canonical role #{role}" do
        stub_collaborators([collaborator("alice", role)])
        expect(service.read_repository("app").role_for("ALICE")).to eq(role)
      end
    end

    it "rejects malformed, unsupported and duplicate direct collaborators" do
      [{}, collaborator("alice", nil), collaborator("alice", "custom")].each do |invalid|
        stub_collaborators([invalid])
        expect { service.read_repository("app") }.to raise_error(backend::Error, /Malformed repository collaborator/)
      end
      stub_collaborators([collaborator("alice"), collaborator("ALICE")])
      expect { service.read_repository("app") }.to raise_error(backend::Error, /Duplicate/)
    end

    it "does not validate collaborator login formats" do
      stub_collaborators([collaborator("../alice")])
      expect(service.read_repository("app").role_for("../alice")).to eq("write")
    end

    it "surfaces collaborator REST failures" do
      request = stub_request(:get, "https://api.github.com/repos/example/app/collaborators")
        .with(query: { affiliation: "direct", per_page: 100 })
        .to_return(status: 403, body: '{"message":"denied"}', headers: { "Content-Type" => "application/json" })
      expect { service.read_repository("app") }.to raise_error(backend::Error, /Reading collaborators/)
      expect(request).to have_been_requested.once
    end

    described_class::ROLES.each do |role, permission|
      it "upserts #{role} with REST #{permission} in exactly one PUT" do
        request = stub_request(:put, "https://api.github.com/repos/example/app/collaborators/alice")
          .with(body: { permission: permission }).to_return(status: 204)
        service.sync_repository("app", [{ action: :upsert, login: "alice", permission: permission }])
        expect(request).to have_been_requested.once
      end
    end

    it "applies upserts before removals and invalidates a cached snapshot" do
      stub_collaborators([collaborator("alice")])
      service.read_repository("app")
      order = []
      stub_request(:put, "https://api.github.com/repos/example/app/collaborators/bob").to_return do
        order << :put
        { status: 204 }
      end
      stub_request(:delete, "https://api.github.com/repos/example/app/collaborators/alice").to_return do
        order << :delete
        { status: 204 }
      end
      service.sync_repository("app", [{ action: :remove, login: "alice" }, { action: :upsert, login: "bob", permission: "push" }])
      expect(order).to eq([:put, :delete])
      stub_collaborators([collaborator("bob")])
      expect(service.read_repository("app").roles).to eq("bob" => "write")
    end

    it "reports invitations without claiming active access" do
      stub_request(:put, "https://api.github.com/repos/example/app/collaborators/alice")
        .to_return(status: 201, body: '{"id":1}', headers: { "Content-Type" => "application/json" })
      expect(logger).to receive(:warn).with(/invitation created.*not yet active/)
      service.sync_repository("app", [{ action: :upsert, login: "alice", permission: "pull" }])
    end

    it "rejects malformed invitation responses and unexpected deletion responses" do
      ["null", "{}", '{"id":0}', '{"id":"1"}'].each do |body|
        stub_request(:put, "https://api.github.com/repos/example/app/collaborators/alice")
          .to_return(status: 201, body: body, headers: { "Content-Type" => "application/json" })
        expect { service.sync_repository("app", [{ action: :upsert, login: "alice", permission: "pull" }]) }
          .to raise_error(backend::Error, /Malformed repository invitation/)
      end
      stub_request(:delete, "https://api.github.com/repos/example/app/collaborators/alice").to_return(status: 201)
      expect { service.sync_repository("app", [{ action: :remove, login: "alice" }]) }
        .to raise_error(backend::Error, /Unexpected repository mutation/)
    end

    [401, 403, 404, 422, 429, 200].each do |status|
      it "surfaces REST HTTP #{status} without retry" do
        request = stub_request(:put, "https://api.github.com/repos/example/app/collaborators/alice")
          .to_return(status: status, body: '{"message":"denied"}', headers: { "Content-Type" => "application/json" })
        expect { service.sync_repository("app", [{ action: :upsert, login: "alice", permission: "push" }]) }.to raise_error(backend::Error)
        expect(request).to have_been_requested.once
      end
    end

    it "retries server failures on idempotent REST mutations" do
      request = stub_request(:put, "https://api.github.com/repos/example/app/collaborators/alice")
        .to_return({ status: 502 }, { status: 204 })
      service.sync_repository("app", [{ action: :upsert, login: "alice", permission: "push" }])
      expect(request).to have_been_requested.twice
    end

    it "stops on a partial failure without removing anyone or caching success" do
      stub_collaborators([collaborator("carol")])
      service.read_repository("app")
      stub_request(:put, "https://api.github.com/repos/example/app/collaborators/alice").to_return(status: 204)
      failed = stub_request(:put, "https://api.github.com/repos/example/app/collaborators/bob").to_return(status: 500)
      instructions = [{ action: :upsert, login: "alice", permission: "push" },
        { action: :upsert, login: "bob", permission: "push" }, { action: :remove, login: "carol" }]
      expect { service.sync_repository("app", instructions) }.to raise_error(backend::Error)
      expect(failed).to have_been_requested.times(3)
      expect(a_request(:delete, /collaborators/)).not_to have_been_made
      stub_collaborators([collaborator("alice"), collaborator("carol")])
      expect(service.read_repository("app").roles.keys).to eq(%w[alice carol])
    end

    it "rejects unknown instructions, invalid permissions, and non-member targets" do
      [
        { action: :oops, login: "alice" },
        { action: :upsert, login: "alice", permission: "custom" },
        { action: :upsert, login: "outsider", permission: "pull" }
      ].each do |instruction|
        expect { service.sync_repository("app", [instruction]) }.to raise_error(backend::Error)
      end
    end

    it "uses GHES REST API paths" do
      enterprise = backend::Service.new(org: "example", token: "test-token", ou: base, addr: "https://github.test/api/v3/")
      allow(enterprise).to receive(:active_members).and_return(members)
      allow(enterprise).to receive(:organization_access).and_return(organization_access)
      stub_teams([], endpoint: "https://github.test/api/v3/repos/example/app/teams")
      stub_collaborators([collaborator("alice")],
        endpoint: "https://github.test/api/v3/repos/example/app/collaborators")
      expect(enterprise.read_repository("app").role_for("alice")).to eq("write")
      request = stub_request(:delete, "https://github.test/api/v3/repos/example/app/collaborators/alice").to_return(status: 204)
      enterprise.sync_repository("app", [{ action: :remove, login: "alice" }])
      expect(request).to have_been_requested.once
    end

    it "paginates repository teams including empty teams, independent of collaborators" do
      stub_collaborators
      stub_request(:get, "https://api.github.com/repos/example/app/teams").with(query: { per_page: 100 })
        .to_return(status: 200, body: '[{"id":1,"slug":"empty","parent":null,"type":"organization","access_source":"direct"}]',
          headers: { "Content-Type" => "application/json", "Link" => '<https://api.github.com/repos/example/app/teams?page=2&per_page=100>; rel="next"' })
      stub_request(:get, "https://api.github.com/repos/example/app/teams").with(query: { per_page: 100, page: 2 })
        .to_return(status: 200, body: '[{"id":2,"slug":"child","parent":{"id":1},"type":"organization","access_source":"direct"}]', headers: { "Content-Type" => "application/json" })
      snapshot = service.read_repository("app")
      expect(snapshot.roles).to be_empty
      expect(snapshot.ordered_teams).to eq([team(1, "empty"), team(2, "child", 1)])
    end

    it "rejects inaccessible or malformed repository team lists" do
      stub_collaborators
      ["{}", "[{}]", '[{"id":1,"slug":"team","parent":{}}]',
        '[{"id":0,"slug":"team","parent":null,"type":"organization","access_source":"direct"}]'].each do |body|
        stub_request(:get, "https://api.github.com/repos/example/app/teams").with(query: { per_page: 100 })
          .to_return(status: 200, body: body, headers: { "Content-Type" => "application/json" })
        expect { service.read_repository("app") }.to raise_error(backend::Error, /Malformed/)
      end
      stub_request(:get, "https://api.github.com/repos/example/app/teams").with(query: { per_page: 100 }).to_return(status: 403)
      expect { service.read_repository("app") }.to raise_error(backend::Error, /Reading teams/)
    end

    it "uses one team snapshot while removing parents before child associations" do
      entries = [{ id: 1, slug: "parent", parent: nil }, { id: 2, slug: "child", parent: { id: 1 } },
        { id: 3, slug: "inherited", parent: { id: 1 } }]
      teams_request = stub_teams(entries)
      order = []
      stub_request(:put, "https://api.github.com/repos/example/app/collaborators/alice").to_return do
        order << :user
        { status: 204 }
      end
      stub_request(:delete, "https://api.github.com/orgs/example/teams/parent/repos/example/app").to_return do
        order << :parent
        { status: 204 }
      end
      stub_request(:delete, "https://api.github.com/orgs/example/teams/child/repos/example/app").to_return do
        order << :child
        { status: 204 }
      end
      stub_request(:delete, "https://api.github.com/orgs/example/teams/inherited/repos/example/app").to_return do
        order << :inherited
        { status: 204 }
      end
      instructions = entries.map { |entry| { action: :remove_team, team_id: entry[:id], slug: entry[:slug] } }
      service.sync_repository("app", instructions + [{ action: :upsert, login: "alice", permission: "pull" }])
      expect(order).to eq([:user, :parent, :child, :inherited])
      expect(teams_request).to have_been_requested.once
    end

    it "surfaces failed team removals and changed team identities" do
      stub_teams([{ id: 1, slug: "engineering", parent: nil }])
      instruction = { action: :remove_team, team_id: 1, slug: "engineering" }
      [403, 200].each do |status|
        stub_request(:delete, "https://api.github.com/orgs/example/teams/engineering/repos/example/app").to_return(status: status)
        expect { service.sync_repository("app", [instruction]) }.to raise_error(backend::Error)
      end
      expect { service.sync_repository("app", [instruction.merge(slug: "renamed")]) }.to raise_error(backend::Error, /identity changed/)
    end
  end
end
