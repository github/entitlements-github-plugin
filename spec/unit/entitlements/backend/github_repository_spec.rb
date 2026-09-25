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

  def stub_organization(base_role: "none", roles: [])
    stub_request(:get, "https://api.github.com/orgs/example")
      .to_return(status: 200, body: JSON.generate(default_repository_permission: base_role), headers: { "Content-Type" => "application/json" })
    stub_request(:get, "https://api.github.com/orgs/example/organization-roles")
      .to_return(status: 200, body: JSON.generate(total_count: roles.size, roles: roles), headers: { "Content-Type" => "application/json" })
  end

  before do
    stub_teams
    stub_organization
  end

  def edge(login, role = "write", sources: nil)
    { "node" => { "login" => login }, "permission" => "ADMIN",
      "permissionSources" => sources || [{ "roleName" => role, "source" => { "__typename" => "Repository" } }] }
  end

  def page(edges, more: false, cursor: nil)
    { "data" => { "repository" => { "collaborators" => {
      "edges" => edges, "pageInfo" => { "hasNextPage" => more, "endCursor" => cursor }
    } } } }
  end

  def stub_page(body, endpoint: "https://api.github.com/graphql")
    stub_request(:post, endpoint).to_return(status: 200, body: JSON.generate(body))
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
      ["features", ["invite"]], ["features", nil], ["ignore", "alice"], ["ignore", [7]],
      ["ignore", ["../alice"]], ["org", "bad/org"], ["allowed_types", ["json"]],
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
      expect(model.equals?(access("alice" => "write", "bob" => "maintain"))).to be(false)
      expect(model.equals?(access({ "alice" => "read", "bob" => "maintain" }, repository: "other"))).to be(false)
      expect(model.equals?(:none)).to be(false)
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

    ["", ".", "..", "bad/repo", "bad repo", "a" * 101, nil].each do |name|
      it "rejects repository name #{name.inspect}" do
        expect { access({}, repository: name) }.to raise_error(backend::Error, /repository name/)
      end
    end

    it "rejects custom roles, invalid logins, and duplicate case variants" do
      expect { access("alice" => "custom") }.to raise_error(backend::Error, /Unsupported/)
      expect { access("../alice" => "write") }.to raise_error(backend::Error, /login/)
      expect { access("alice" => "read", "ALICE" => "write") }.to raise_error(backend::Error, /Duplicate/)
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
        action = provider.action_for(access("ALICE" => "admin", "carol" => "triage"), "repos")
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
          expect(action.existing.equals?(action.updated)).to be(false)
        end
      end
    end

    it "ignores configured users on both sides and handles case-only changes as no-op" do
      config["ignore"] = ["OWNER", "Bob"]
      allow(service).to receive(:read_repository).and_return(access("alice" => "read", "bob" => "admin"))
      expect(provider.action_for(access("ALICE" => "read", "owner" => "write"), "repos")).to be_nil
    end

    it "rejects desired non-members before reading a repository" do
      expect(service).not_to receive(:read_repository)
      expect { provider.action_for(access("outsider" => "read"), "repos") }.to raise_error(backend::Error, /not active/)
    end

    it "warns and ignores non-members when explicitly configured" do
      config["ignore_not_found"] = true
      expect(logger).to receive(:warn).with(/outsider.*ignored/)
      allow(service).to receive(:read_repository).and_return(access)
      expect(provider.action_for(access("outsider" => "read"), "repos")).to be_nil
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
      expect(service).to receive(:apply).with("app", [{ action: :upsert, login: "alice", permission: "maintain" }]) do
        allow(service).to receive(:read_repository).and_return(desired)
      end
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
      expect { provider.action_for(access, "repos") }.to raise_error(backend::Error, /Missing organization access snapshot/)
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
      action = provider.action_for(access("alice" => "read"), "repos")
      expect(action.updated.teams).to eq(action.existing.teams)
      expect(action.implementation.map { |instruction| instruction[:action] }).to eq([:upsert])
    end

    it "removes undeclared outside direct grants as well as all direct teams" do
      allow(service).to receive(:read_repository).and_return(access("outsider" => "read", :teams => [team]))
      action = provider.action_for(access("alice" => "read"), "repos")
      expect(action.implementation.map { |instruction| instruction[:action] }).to eq([:upsert, :remove, :remove_team])
      expect(action.updated.roles).to eq("alice" => "read")
    end

    it "rejects stale plans before mutation and rejects residual grants after apply" do
      allow(service).to receive(:read_repository).and_return(access(teams: [team]))
      action = provider.action_for(access, "repos")
      allow(service).to receive(:read_repository).with("app", refresh: true).and_return(access)
      expect(service).not_to receive(:apply)
      expect { provider.commit(action) }.to raise_error(backend::Error, /changed since calculation/)
      RSpec::Mocks.space.proxy_for(service).reset
      allow(service).to receive(:read_repository).with("app", refresh: true).and_return(action.existing)
      expect(service).to receive(:apply).with("app", action.implementation)
      expect { provider.commit(action) }.to raise_error(backend::Error, /did not converge/)
    end

    it "accepts desired owners without ignore_not_found and defers their ambiguous direct grants" do
      allow(service).to receive(:read_repository).and_return(access(teams: [team], organization_access: organization_access))
      expect(logger).to receive(:warn).with(/DEFER app: owner.*inherited admin.*organization ownership/)
      action = provider.action_for(access("owner" => "read"), "repos")
      expect(action.implementation).to eq([{ action: :remove_team, team_id: 1, slug: "engineering" }])
      expect(action.ignored_users).to be_empty
    end

    described_class::ROLES.each_key do |role|
      it "handles all-repository #{role} assignments and provisions equal direct grants" do
        inherited = organization_access(assignments: { "alice" => [organization_role(10, role, "arbitrary-#{role}")] })
        allow(service).to receive(:read_repository).and_return(access(organization_access: inherited))
        action = provider.action_for(access("alice" => role), "repos")
        expect(action.implementation).to eq([{ action: :upsert, login: "alice", permission: backend::ROLES.fetch(role) }])
      end
    end

    it "defers lower desired roles without inventing a successful direct grant or raising inherited privileges" do
      inherited = organization_access(assignments: { "alice" => [organization_role] })
      current = access({ "alice" => "admin" }, teams: [team], organization_access: inherited)
      allow(service).to receive(:read_repository).and_return(current)
      expect(logger).to receive(:warn).with(/DEFER app: alice direct role read; inherited write/)
      action = provider.action_for(access("alice" => "read"), "repos")
      expect(action.updated.roles).to eq("alice" => "admin")
      expect(action.implementation.map { |entry| entry[:action] }).to eq([:remove_team])
    end

    it "defers roles below organization base and continues to provision users above the base" do
      allow(service).to receive(:read_repository).and_return(access(organization_access: organization_access(base_role: "write")))
      expect(logger).to receive(:warn).with(/DEFER app: alice.*organization base write/)
      action = provider.action_for(access("alice" => "read", "bob" => "admin"), "repos")
      expect(action.updated.roles).to eq("bob" => "admin")
    end

    it "removes undeclared direct grants even when a non-owner retains organization-wide access" do
      inherited = organization_access(assignments: { "alice" => [organization_role] })
      allow(service).to receive(:read_repository).and_return(access({ "alice" => "admin" }, organization_access: inherited))
      action = provider.action_for(access, "repos")
      expect(action.implementation).to eq([{ action: :remove, login: "alice" }])
    end

    it "preserves organization and enterprise team sources while removing a direct association" do
      teams = [team, team(2, "security", nil, "organization"), team(3, "enterprise", nil, "enterprise")]
      allow(service).to receive(:read_repository).and_return(access(teams: teams, organization_access: organization_access))
      action = provider.action_for(access, "repos")
      expect(action.implementation).to eq([{ action: :remove_team, team_id: 1, slug: "engineering" }])
      expect(action.updated.teams.keys).to eq([2, 3])
      # A direct association can mask an organization-wide source for the same team.
      expect(action.updated).to eq(access(teams: teams.map { |entry| entry.merge(access_source: "organization") },
        organization_access: organization_access))
    end

    it "plans a direct grant after owner JIT expires and rejects plans if organization access changes" do
      elevated = organization_access
      demoted = organization_access(membership: members.merge("owner" => "member"))
      allow(service).to receive(:read_repository).and_return(access(organization_access: elevated))
      expect(provider.action_for(access("owner" => "read"), "repos")).to be_nil
      allow(service).to receive(:read_repository).and_return(access(organization_access: demoted))
      action = provider.action_for(access("owner" => "read"), "repos")
      expect(action.implementation).to eq([{ action: :upsert, login: "owner", permission: "pull" }])
      allow(service).to receive(:read_repository).with("app", refresh: true).and_return(access(organization_access: elevated))
      expect(service).not_to receive(:apply)
      expect { provider.commit(action) }.to raise_error(backend::Error, /changed since calculation/)
    end
  end

  describe "end-to-end reconciliation" do
    it "converges to individual-only grants, removing teams and undeclared direct grants" do
      cache[:people_obj] = Entitlements::Data::People::YAML.new(filename: fixture("people.yaml"))
      cache[:file_objects] = {}
      stub_request(:get, "https://api.github.com/orgs/example/members")
        .with(query: { role: "admin", per_page: 100 })
        .to_return(status: 200, body: '[{"login":"owner"}]', headers: { "Content-Type" => "application/json" })
      members_request = stub_request(:get, "https://api.github.com/orgs/example/members")
        .with(query: { role: "member", per_page: 100 })
        .to_return(status: 200, body: '[{"login":"balinese"},{"login":"bob"},{"login":"carol"}]',
          headers: { "Content-Type" => "application/json" })
      inherited = edge("carol", sources: [{ "roleName" => "admin", "source" => { "__typename" => "Team" } }])
      initial = page([edge("balinese", "read"), edge("bob"), edge("outsider"), edge("owner"), inherited])
      final = page([edge("balinese", "write")])
      stub_request(:post, "https://api.github.com/graphql").to_return(
        { status: 200, body: JSON.generate(initial) },
        { status: 200, body: JSON.generate(initial) },
        { status: 200, body: JSON.generate(final) }
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
      expect(members_request).to have_been_requested.times(3)
      expect(remove_team).to have_been_requested.once
      expect(a_request(:delete, "https://api.github.com/repos/example/app/collaborators/carol")).not_to have_been_made
      expect(a_request(:delete, "https://api.github.com/repos/example/app/collaborators/owner")).not_to have_been_made
    end
  end

  describe "GitHub transport" do
    before do
      allow(service).to receive(:members_and_roles_from_rest).and_return(members.transform_values(&:upcase))
    end

    it "uses live installation-specific organization membership and accepts owners" do
      expect(service).not_to receive(:org_members)
      expect(service.active_members).to eq(members)
    end

    it "reads all catalog roles and paginates direct, indirect and mixed user assignments" do
      roles = [organization_role, organization_role(11, nil, "custom-org-capabilities"),
        organization_role(12, "read", "security_manager")]
      stub_organization(roles: roles)
      stub_request(:get, "https://api.github.com/orgs/example/organization-roles/10/users").with(query: { per_page: 100 })
        .to_return(status: 200, body: '[{"login":"ALICE","assignment":"direct"}]',
          headers: { "Content-Type" => "application/json", "Link" => '<https://api.github.com/orgs/example/organization-roles/10/users?page=2&per_page=100>; rel="next"' })
      stub_request(:get, "https://api.github.com/orgs/example/organization-roles/10/users").with(query: { per_page: 100, page: 2 })
        .to_return(status: 200, body: '[{"login":"bob","assignment":"indirect"},{"login":"carol","assignment":"mixed"}]',
          headers: { "Content-Type" => "application/json" })
      [11, 12].each do |id|
        stub_request(:get, "https://api.github.com/orgs/example/organization-roles/#{id}/users").with(query: { per_page: 100 })
          .to_return(status: 200, body: '[{"login":"alice","assignment":"indirect"}]', headers: { "Content-Type" => "application/json" })
      end
      context = service.organization_access
      expect(context.assignments["alice"].size).to eq(3)
      expect(context.inherited_role("alice")).to eq("write")
      expect(context.inherited_role("bob")).to eq("write")
      expect(context.inherited_role("carol")).to eq("write")
      expect(context.sources("alice")).to include('organization role "security_manager"', 'organization role "custom-org-capabilities"')
    end

    it "fails closed when organization settings, role catalog or assignments are unavailable" do
      stub_request(:get, "https://api.github.com/orgs/example").to_return(status: 200, body: "null",
        headers: { "Content-Type" => "application/json" })
      expect { service.organization_access }.to raise_error(backend::Error, /Missing organization access/)
      stub_organization(base_role: nil)
      expect { service.organization_access }.to raise_error(backend::Error, /Malformed organization access/)
      stub_organization
      ["{}", '{"roles":[],"total_count":1}', '{"roles":null,"total_count":0}'].each do |body|
        stub_request(:get, "https://api.github.com/orgs/example/organization-roles")
          .to_return(status: 200, body: body, headers: { "Content-Type" => "application/json" })
        expect { service.organization_access }.to raise_error(backend::Error, /Incomplete/)
      end
      [403, 404].each do |status|
        stub_request(:get, "https://api.github.com/orgs/example/organization-roles").to_return(status: status)
        expect { service.organization_access }.to raise_error(backend::Error, /Reading organization access/)
      end
    end

    it "rejects malformed or unsupported roles and malformed or duplicate assignees" do
      [organization_role(0), organization_role(10, "unknown"), organization_role.merge(permissions: [nil]),
        organization_role.reject { |key, _| key == :base_role }].each do |role|
        stub_organization(roles: [role])
        expect { service.organization_access }.to raise_error(backend::Error, /Malformed organization role/)
      end
      stub_organization(roles: [organization_role])
      ["{}", "[{}]", '[{"login":"alice","assignment":"unknown"}]',
        '[{"login":"alice","assignment":"direct"},{"login":"ALICE","assignment":"indirect"}]'].each do |body|
        stub_request(:get, "https://api.github.com/orgs/example/organization-roles/10/users").with(query: { per_page: 100 })
          .to_return(status: 200, body: body, headers: { "Content-Type" => "application/json" })
        expect { service.organization_access }.to raise_error(backend::Error)
      end
    end

    it "does not treat synthetic owner Repository grants as removable direct grants" do
      sources = [{ "source" => { "__typename" => "Organization" }, "roleName" => nil },
        { "source" => { "__typename" => "Repository" }, "roleName" => "admin" },
        { "source" => { "__typename" => "Repository" }, "roleName" => "read" }]
      stub_page(page([edge("owner", sources: sources)]))
      expect(service.read_repository("app").roles).to be_empty
    end

    it "rejects owner mutations even if an invalid instruction bypassed the planner" do
      [:upsert, :remove].each do |action|
        expect { service.apply("app", [{ action: action, login: "owner", permission: "pull" }]) }
          .to raise_error(backend::Error, /owner.*deferred/)
      end
      expect(a_request(:put, /collaborators/)).not_to have_been_made
      expect(a_request(:delete, /collaborators/)).not_to have_been_made
    end

    it "preserves enterprise permission sources and reads only an accompanying explicit user grant" do
      sources = [{ "source" => { "__typename" => "EnterpriseTeam" }, "roleName" => "admin" },
        { "source" => { "__typename" => "Repository" }, "roleName" => "read" }]
      stub_page(page([edge("alice", sources: sources)]))
      stub_teams([{ id: 9, slug: "enterprise", parent: nil, type: "enterprise", access_source: "enterprise" }])
      snapshot = service.read_repository("app")
      expect(snapshot.roles).to eq("alice" => "read")
      expect(snapshot.direct_teams).to be_empty
    end

    it "rejects team lists without source metadata instead of guessing that grants are direct" do
      stub_page(page([]))
      stub_teams([{ id: 1, slug: "team", parent: nil, access_source: nil }])
      expect { service.read_repository("app") }.to raise_error(backend::Error, /access_source/)
      stub_teams([{ id: 1, slug: "team", parent: nil, type: "enterprise" }])
      expect { service.read_repository("app") }.to raise_error(backend::Error, /access_source/)
    end

    it "refuses to delete a team whose source became organization-wide" do
      stub_teams([{ id: 1, slug: "team", parent: nil, access_source: "organization" }])
      expect { service.apply("app", [{ action: :remove_team, team_id: 1, slug: "team" }]) }
        .to raise_error(backend::Error, /access source changed/)
      expect(a_request(:delete, /teams/)).not_to have_been_made
    end

    it "paginates, uses direct roles instead of effective permissions, and caches per repository" do
      first = page([edge("Alice", "Read"), edge("outsider"), edge("owner")], more: true, cursor: 'a"b')
      inherited = %w[Team Organization].map { |type| { "roleName" => "admin", "source" => { "__typename" => type } } }
      second = page([edge("Bob", "triage", sources: inherited), edge("Carol", "maintain")])
      request = stub_request(:post, "https://api.github.com/graphql")
        .with(headers: { "Authorization" => "bearer test-token" })
        .to_return({ status: 200, body: JSON.generate(first) }, { status: 200, body: JSON.generate(second) })
      expect(service.read_repository("app").roles).to eq("alice" => "read", "carol" => "maintain", "outsider" => "write")
      expect(service.read_repository("APP").roles).to eq("alice" => "read", "carol" => "maintain", "outsider" => "write")
      expect(request).to have_been_requested.twice
      expect(a_request(:post, "https://api.github.com/graphql").with { |req|
        JSON.parse(req.body).fetch("query").include?('after: "a\\"b"')
      }).to have_been_made.once
    end

    it "selects the direct role even alongside a higher inherited grant" do
      sources = [{ "roleName" => "admin", "source" => { "__typename" => "Team" } },
        { "roleName" => "triage", "source" => { "__typename" => "Repository" } }]
      stub_page(page([edge("alice", sources: sources)]))
      expect(service.read_repository("app").roles).to eq("alice" => "triage")
    end

    it "does not request the unused effective permission field or its additional token scope" do
      request = stub_request(:post, "https://api.github.com/graphql").with do |req|
        query = JSON.parse(req.body).fetch("query")
        query.include?("permissionSources { roleName") && !query.match?(/\bpermission\b/)
      end.to_return(status: 200, body: JSON.generate(page([edge("alice", "read").reject { |key, _| key == "permission" }])))
      expect(service.read_repository("app").roles).to eq("alice" => "read")
      expect(request).to have_been_requested.once
    end

    described_class::ROLES.each_key do |role|
      it "reads canonical role #{role}" do
        stub_page(page([edge("alice", role)]))
        expect(service.read_repository("app").role_for("ALICE")).to eq(role)
      end
    end

    [
      {}, { "data" => nil }, { "data" => { "repository" => nil } },
      { "data" => { "repository" => { "collaborators" => {} } } },
      { "errors" => [{ "message" => "denied" }] },
      { "data" => { "repository" => { "collaborators" => { "edges" => [], "pageInfo" => {} } } } }
    ].each do |body|
      it "fails closed on missing or partial GraphQL data #{body.inspect}" do
        stub_page(body)
        expect { service.read_repository("app") }.to raise_error(backend::Error)
      end
    end

    it "rejects missing sources, unsupported roles, malformed sources and duplicate direct grants" do
      [
        edge("alice").merge("permissionSources" => nil),
        edge("alice", nil), edge("alice", "custom"),
        edge("alice", sources: [nil]),
        edge("alice", sources: [{ "source" => {} }]),
        edge("alice", sources: [{ "source" => { "__typename" => nil } }]),
        edge("alice", sources: []),
        edge("alice", sources: [edge("alice")["permissionSources"].first] * 2),
        edge("../alice")
      ].each do |invalid|
        stub_page(page([invalid]))
        expect { service.read_repository("app") }.to raise_error(backend::Error)
      end
      stub_page(page([edge("alice"), edge("ALICE")]))
      expect { service.read_repository("app") }.to raise_error(backend::Error, /Duplicate/)
    end

    it "rejects invalid or non-advancing pagination" do
      [page([], more: nil), page([], more: true), page([], more: true, cursor: "")].each do |body|
        stub_page(body)
        expect { service.read_repository("app") }.to raise_error(backend::Error, /pagination/)
      end
      stub_page(page([], more: true, cursor: "repeat"))
      expect { service.read_repository("app") }.to raise_error(backend::Error, /repeated/)
    end

    it "surfaces HTTP and malformed JSON failures" do
      [403, 500].each do |status|
        stub_request(:post, "https://api.github.com/graphql").to_return(status: status, body: "denied")
        expect { service.read_repository("app") }.to raise_error(backend::Error, /GraphQL/)
      end
      stub_request(:post, "https://api.github.com/graphql").to_return(status: 200, body: "{broken")
      expect { service.read_repository("app") }.to raise_error(backend::Error, /GraphQL/)
    end

    it "recovers from a transient GraphQL error" do
      request = stub_request(:post, "https://api.github.com/graphql").to_return(
        { status: 502 }, { status: 200, body: JSON.generate(page([])) }
      )
      expect(service.read_repository("app").roles).to eq({})
      expect(request).to have_been_requested.twice
    end

    described_class::ROLES.each do |role, permission|
      it "upserts #{role} with REST #{permission} in exactly one PUT" do
        request = stub_request(:put, "https://api.github.com/repos/example/app/collaborators/alice")
          .with(body: { permission: permission }).to_return(status: 204)
        service.apply("app", [{ action: :upsert, login: "alice", permission: permission }])
        expect(request).to have_been_requested.once
      end
    end

    it "applies upserts before removals and invalidates a cached snapshot" do
      stub_page(page([edge("alice")]))
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
      service.apply("app", [{ action: :remove, login: "alice" }, { action: :upsert, login: "bob", permission: "push" }])
      expect(order).to eq([:put, :delete])
      stub_page(page([edge("bob")]))
      expect(service.read_repository("app").roles).to eq("bob" => "write")
    end

    it "reports invitations without claiming active access" do
      stub_request(:put, "https://api.github.com/repos/example/app/collaborators/alice")
        .to_return(status: 201, body: '{"id":1}', headers: { "Content-Type" => "application/json" })
      expect(logger).to receive(:warn).with(/invitation created.*not yet active/)
      service.apply("app", [{ action: :upsert, login: "alice", permission: "pull" }])
    end

    it "rejects malformed invitation responses and unexpected deletion responses" do
      ["null", "{}", '{"id":0}', '{"id":"1"}'].each do |body|
        stub_request(:put, "https://api.github.com/repos/example/app/collaborators/alice")
          .to_return(status: 201, body: body, headers: { "Content-Type" => "application/json" })
        expect { service.apply("app", [{ action: :upsert, login: "alice", permission: "pull" }]) }
          .to raise_error(backend::Error, /Malformed repository invitation/)
      end
      stub_request(:delete, "https://api.github.com/repos/example/app/collaborators/alice").to_return(status: 201)
      expect { service.apply("app", [{ action: :remove, login: "alice" }]) }
        .to raise_error(backend::Error, /Unexpected repository mutation/)
    end

    [401, 403, 404, 422, 429, 200].each do |status|
      it "surfaces REST HTTP #{status} without retry" do
        request = stub_request(:put, "https://api.github.com/repos/example/app/collaborators/alice")
          .to_return(status: status, body: '{"message":"denied"}', headers: { "Content-Type" => "application/json" })
        expect { service.apply("app", [{ action: :upsert, login: "alice", permission: "push" }]) }.to raise_error(backend::Error)
        expect(request).to have_been_requested.once
      end
    end

    it "retries server failures on idempotent REST mutations" do
      request = stub_request(:put, "https://api.github.com/repos/example/app/collaborators/alice")
        .to_return({ status: 502 }, { status: 204 })
      service.apply("app", [{ action: :upsert, login: "alice", permission: "push" }])
      expect(request).to have_been_requested.twice
    end

    it "stops on a partial failure without removing anyone or caching success" do
      stub_page(page([edge("carol")]))
      service.read_repository("app")
      stub_request(:put, "https://api.github.com/repos/example/app/collaborators/alice").to_return(status: 204)
      failed = stub_request(:put, "https://api.github.com/repos/example/app/collaborators/bob").to_return(status: 500)
      instructions = [{ action: :upsert, login: "alice", permission: "push" },
        { action: :upsert, login: "bob", permission: "push" }, { action: :remove, login: "carol" }]
      expect { service.apply("app", instructions) }.to raise_error(backend::Error)
      expect(failed).to have_been_requested.times(3)
      expect(a_request(:delete, /collaborators/)).not_to have_been_made
      stub_page(page([edge("alice"), edge("carol")]))
      expect(service.read_repository("app").roles.keys).to eq(%w[alice carol])
    end

    it "rejects unknown instructions, invalid permissions, and non-member targets" do
      [
        { action: :oops, login: "alice" },
        { action: :upsert, login: "alice", permission: "custom" },
        { action: :upsert, login: "outsider", permission: "pull" }
      ].each do |instruction|
        expect { service.apply("app", [instruction]) }.to raise_error(backend::Error)
      end
    end

    it "uses GHES REST and GraphQL API paths" do
      enterprise = backend::Service.new(org: "example", token: "test-token", ou: base, addr: "https://github.test/api/v3/")
      allow(enterprise).to receive(:active_members).and_return(members)
      allow(enterprise).to receive(:organization_access).and_return(organization_access)
      stub_teams([], endpoint: "https://github.test/api/v3/repos/example/app/teams")
      stub_page(page([edge("alice")]), endpoint: "https://github.test/api/graphql")
      expect(enterprise.read_repository("app").role_for("alice")).to eq("write")
      request = stub_request(:delete, "https://github.test/api/v3/repos/example/app/collaborators/alice").to_return(status: 204)
      enterprise.apply("app", [{ action: :remove, login: "alice" }])
      expect(request).to have_been_requested.once
    end

    it "paginates repository teams including empty teams, independent of collaborators" do
      stub_page(page([]))
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
      stub_page(page([]))
      ["{}", "[{}]", '[{"id":1,"slug":"team","parent":{}}]',
        '[{"id":0,"slug":"team","parent":null,"type":"organization","access_source":"direct"}]'].each do |body|
        stub_request(:get, "https://api.github.com/repos/example/app/teams").with(query: { per_page: 100 })
          .to_return(status: 200, body: body, headers: { "Content-Type" => "application/json" })
        expect { service.read_repository("app") }.to raise_error(backend::Error, /Malformed/)
      end
      stub_request(:get, "https://api.github.com/repos/example/app/teams").with(query: { per_page: 100 }).to_return(status: 403)
      expect { service.read_repository("app") }.to raise_error(backend::Error, /Reading teams/)
    end

    it "removes parents before remaining direct child associations, skipping inherited access that disappeared" do
      entries = [{ id: 1, slug: "parent", parent: nil }, { id: 2, slug: "child", parent: { id: 1 } },
        { id: 3, slug: "inherited", parent: { id: 1 } }]
      stub_teams(entries)
      order = []
      stub_request(:put, "https://api.github.com/repos/example/app/collaborators/alice").to_return do
        order << :user
        { status: 204 }
      end
      stub_request(:delete, "https://api.github.com/orgs/example/teams/parent/repos/example/app").to_return do
        order << :parent
        stub_teams([entries[1]])
        { status: 204 }
      end
      stub_request(:delete, "https://api.github.com/orgs/example/teams/child/repos/example/app").to_return do
        order << :child
        stub_teams
        { status: 204 }
      end
      instructions = entries.map { |entry| { action: :remove_team, team_id: entry[:id], slug: entry[:slug] } }
      service.apply("app", instructions + [{ action: :upsert, login: "alice", permission: "pull" }])
      expect(order).to eq([:user, :parent, :child])
      expect(a_request(:delete, %r{/teams/inherited/})).not_to have_been_made
    end

    it "surfaces failed team removals and changed team identities" do
      stub_teams([{ id: 1, slug: "engineering", parent: nil }])
      instruction = { action: :remove_team, team_id: 1, slug: "engineering" }
      [403, 200].each do |status|
        stub_request(:delete, "https://api.github.com/orgs/example/teams/engineering/repos/example/app").to_return(status: status)
        expect { service.apply("app", [instruction]) }.to raise_error(backend::Error)
      end
      expect { service.apply("app", [instruction.merge(slug: "renamed")]) }.to raise_error(backend::Error, /identity changed/)
    end
  end
end
