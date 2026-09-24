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

  def access(roles = {}, repository: "app", **inline_roles)
    backend::Models::RepositoryAccess.new(repository: repository, roles: roles.merge(inline_roles), ou: base)
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
      allow(service).to receive(:active_members).and_return(members.reject { |_, role| role == "admin" })
    end

    described_class::FEATURES.length.succ.times.flat_map { |size| described_class::FEATURES.combination(size).to_a }.each do |features|
      it "honors feature combination #{features.inspect} in instructions and displayed state" do
        config["features"] = features
        allow(service).to receive(:read_repository).with("app").and_return(access("alice" => "read", "bob" => "write"))
        action = provider.action_for(access("ALICE" => "admin", "carol" => "triage"), "repos")
        if features.empty?
          expect(action).to be_nil
        else
          expected = []
          expected << { action: :upsert, login: "ALICE", permission: "admin" } if features.include?("update")
          expected << { action: :upsert, login: "carol", permission: "triage" } if features.include?("add")
          expected << { action: :remove, login: "bob" } if features.include?("remove")
          expect(action.implementation).to eq(expected)
          effective = { "alice" => features.include?("update") ? "admin" : "read" }
          effective["carol"] = "triage" if features.include?("add")
          effective["bob"] = "write" unless features.include?("remove")
          expect(action.updated.roles).to eq(effective)
          expect(action.existing.equals?(action.updated)).to be(false)
        end
      end
    end

    it "ignores configured users on both sides and handles case-only changes as no-op" do
      config["ignore"] = ["OWNER", "Bob"]
      allow(service).to receive(:read_repository).and_return(access("alice" => "read", "bob" => "admin"))
      expect(provider.action_for(access("ALICE" => "read", "owner" => "write"), "repos")).to be_nil
    end

    it "rejects desired non-members and owners before reading a repository" do
      expect(service).not_to receive(:read_repository)
      expect { provider.action_for(access("outsider" => "read"), "repos") }.to raise_error(backend::Error, /not active/)
      expect { provider.action_for(access("owner" => "read"), "repos") }.to raise_error(backend::Error, /not active/)
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
      expect(service).to receive(:apply).with("app", [{ action: :upsert, login: "alice", permission: "maintain" }])
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
  end

  describe "end-to-end reconciliation" do
    it "converges on a second calculation, preserving inherited and outside access" do
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
      preserved = [edge("outsider"), edge("owner"), inherited]
      stub_page(page([edge("balinese", "read"), edge("bob")] + preserved))
      put = stub_request(:put, "https://api.github.com/repos/example/app/collaborators/balinese")
        .with(body: { permission: "push" }).to_return(status: 204)
      delete = stub_request(:delete, "https://api.github.com/repos/example/app/collaborators/bob").to_return(status: 204)
      Dir.mktmpdir do |root|
        Dir.mkdir("#{root}/app")
        File.write("#{root}/app/write.txt", "username = balinese\n")
        controller = backend::Controller.new("repos", config.merge("dir" => root))
        actions = controller.calculate
        expect(actions.size).to eq(1)
        expect(actions.first.implementation.size).to eq(2)
        controller.apply(actions.first)
        stub_page(page([edge("balinese", "write")] + preserved))
        expect(controller.calculate).to eq([])
      end
      expect(put).to have_been_requested.once
      expect(delete).to have_been_requested.once
      expect(members_request).to have_been_requested.once
      %w[owner outsider carol].each do |login|
        expect(a_request(:delete, "https://api.github.com/repos/example/app/collaborators/#{login}")).not_to have_been_made
      end
    end
  end

  describe "GitHub transport" do
    before do
      allow(service).to receive(:org_members).and_return(members)
      allow(service).to receive(:org_members_from_predictive_cache?).and_return(false)
    end

    it "uses the organization membership cache and excludes owners" do
      expect(service).to receive(:invalidate_org_members_predictive_cache)
      expect(service.active_members).to eq(members.reject { |_, role| role == "admin" })
    end

    it "paginates, uses direct roles instead of effective permissions, and caches per repository" do
      first = page([edge("Alice", "Read"), edge("outsider"), edge("owner")], more: true, cursor: 'a"b')
      inherited = %w[Team Organization EnterpriseTeam].map { |type| { "roleName" => "admin", "source" => { "__typename" => type } } }
      second = page([edge("Bob", "triage", sources: inherited), edge("Carol", "maintain")])
      request = stub_request(:post, "https://api.github.com/graphql")
        .with(headers: { "Authorization" => "bearer test-token" })
        .to_return({ status: 200, body: JSON.generate(first) }, { status: 200, body: JSON.generate(second) })
      expect(service.read_repository("app").roles).to eq("alice" => "read", "carol" => "maintain")
      expect(service.read_repository("APP").roles).to eq("alice" => "read", "carol" => "maintain")
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
        { action: :remove, login: "outsider" }
      ].each do |instruction|
        expect { service.apply("app", [instruction]) }.to raise_error(backend::Error)
      end
    end

    it "uses GHES REST and GraphQL API paths" do
      enterprise = backend::Service.new(org: "example", token: "test-token", ou: base, addr: "https://github.test/api/v3/")
      allow(enterprise).to receive(:active_members).and_return(members)
      stub_page(page([edge("alice")]), endpoint: "https://github.test/api/graphql")
      expect(enterprise.read_repository("app").role_for("alice")).to eq("write")
      request = stub_request(:delete, "https://github.test/api/v3/repos/example/app/collaborators/alice").to_return(status: 204)
      enterprise.apply("app", [{ action: :remove, login: "alice" }])
      expect(request).to have_been_requested.once
    end
  end
end
