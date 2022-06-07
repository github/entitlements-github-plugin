# frozen_string_literal: true

require_relative "spec_helper"

describe Entitlements do
  before(:all) do
    # Initialize organization membership and team membership to a known, consistent state.
    github_teams_reset

    admin = %w[blackmanx ragamuffin donskoy]
    members = %w[nebelung khaomanee cheetoh ojosazules mainecoon chausie cyprus russianblue]
    github_http_put("/entitlements-app-acceptance/orgs/admin", { "users" => admin })
    github_http_put("/entitlements-app-acceptance/orgs/member", { "users" => members })
    github_http_put("/entitlements-app-acceptance/pending", { "users" => [] })

    ENV["ENTITLEMENTS_PREDICTIVE_STATE_DIR"] = fixture("predictive/predictive-state")
    @result = run("predictive", ["--debug"])
  end

  it "returns success" do
    expect(@result.success?).to eq(true)
  end

  it "prints nothing on STDOUT" do
    expect(@result.stdout).to eq("")
  end

  it "indicates that predictive caches are being loaded" do
    expect(@result.stderr).to match(log("DEBUG", "Loading predictive update caches from .+/fixtures/predictive/predictive-state"))
    expect(@result.stderr).to match(log("DEBUG", Regexp.escape("Loaded 3 OU(s) from cache")))
    expect(@result.stderr).to match(log("DEBUG", Regexp.escape("Loaded 7 DN(s) from cache")))
  end

  context "GitHub organizational membership" do
    context "with changes" do
      it "detects the proper change set" do
        expect(@result.stderr).to match(log("INFO", "CHANGE cn=admin,ou=meowsister-org,ou=GitHub,dc=github,dc=fake in github-org"))
        expect(@result.stderr).to match(log("INFO", "CHANGE cn=member,ou=meowsister-org,ou=GitHub,dc=github,dc=fake in github-org"))
      end

      it "invalidates the cache and reloads from the API" do
        expect(@result.stderr).to match(log("DEBUG", "Loading organization members and roles for meowsister from cache"))
        expect(@result.stderr).to match(log("DEBUG", Regexp.escape("Currently meowsister has 2 admin(s) and 5 member(s)")))
        expect(@result.stderr).to match(log("DEBUG", Regexp.escape("Invalidating cache entries for cn=(admin|member),ou=meowsister-org,ou=GitHub,dc=github,dc=fake")))
        expect(@result.stderr).to match(log("DEBUG", Regexp.escape("members(cn=admin,ou=meowsister-org,ou=GitHub,dc=github,dc=fake): DN has been marked invalid in cache")))
        expect(@result.stderr).to match(log("DEBUG", Regexp.escape("members(cn=member,ou=meowsister-org,ou=GitHub,dc=github,dc=fake): DN has been marked invalid in cache")))
        expect(@result.stderr).to match(log("DEBUG", "Loading organization members and roles for meowsister$"))
        expect(@result.stderr).to match(log("DEBUG", Regexp.escape("Currently meowsister has 3 admin(s) and 8 member(s)")))

        expect(@result.stderr).to match(log("DEBUG", Regexp.escape("APPLY: Updating GitHub organization cn=admin,ou=meowsister-org,ou=GitHub,dc=github,dc=fake")))
        expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=mainecoon, org=meowsister, role=admin)")))
        expect(@result.stderr).to match(log("DEBUG", Regexp.escape("sync(admin): Added 1, removed 0")))

        expect(@result.stderr).to match(log("DEBUG", Regexp.escape("APPLY: Updating GitHub organization cn=member,ou=meowsister-org,ou=GitHub,dc=github,dc=fake")))
        expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=donskoy, org=meowsister, role=member)")))
        expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=chausie, org=meowsister)")))
        expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=cyprus, org=meowsister)")))
        expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=ojosazules, org=meowsister)")))
        expect(@result.stderr).to match(log("DEBUG", Regexp.escape("sync(member): Added 1, removed 3")))
      end

      it "creates correct admin group" do
        response = github_http_get("/entitlements-app-acceptance/orgs/admin")
        expect(response.code).to eq("200")
        users = Set.new(JSON.parse(response.body)["users"])
        expected = Set.new(%w[blackmanx mainecoon ragamuffin])
        expect(users).to eq(expected)
      end

      it "creates correct member group" do
        response = github_http_get("/entitlements-app-acceptance/orgs/member")
        expect(response.code).to eq("200")
        users = Set.new(JSON.parse(response.body)["users"])
        expected = Set.new(%w[cheetoh donskoy khaomanee nebelung russianblue])
        expect(users).to eq(expected)
      end
    end

    context "with no changes" do
      it "detects the proper change set" do
        expect(@result.stderr).to match(log("DEBUG", "UNCHANGED: No GitHub organization changes for github-org-2:admin"))
        expect(@result.stderr).to match(log("DEBUG", "UNCHANGED: No GitHub organization changes for github-org-2:member"))
        expect(@result.stderr).to match(log("DEBUG", "UNCHANGED: No GitHub organization changes for github-org-2$"))
      end

      it "uses the cache only and does not load from the API" do
        expect(@result.stderr).to match(log("DEBUG", "Loading organization members and roles for org2 from cache"))
        expect(@result.stderr).not_to match(log("DEBUG", "Loading organization members and roles for org2$"))

        expect(@result.stderr).to match(log("DEBUG", Regexp.escape("Currently org2 has 3 admin(s) and 4 member(s)")))
        expect(@result.stderr).not_to match(log("DEBUG", Regexp.escape("Invalidating cache entries for cn=(admin|member),ou=org2,ou=GitHub,dc=github,dc=fake")))
      end

      it "does not make changes" do
        expect(@result.stderr).not_to match(log("DEBUG", Regexp.escape("APPLY: Updating GitHub organization cn=admin,ou=org2,ou=GitHub,dc=github,dc=fake")))
        expect(@result.stderr).not_to match(log("DEBUG", Regexp.escape("APPLY: Updating GitHub organization cn=member,ou=org2,ou=GitHub,dc=github,dc=fake")))
        expect(@result.stderr).not_to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=.+, org=org2")))
        expect(@result.stderr).not_to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=.+, org=org2")))
      end

      # The /entitlements-app-acceptance/orgs/member endpoint is now aware of the specific organization because
      # it's just a stub. By checking that the members still match the definition from the "meowsister" organization
      # established previously, we can confirm that there were no changes written to the API in this test.
      it "still has the correct member group" do
        response = github_http_get("/entitlements-app-acceptance/orgs/member")
        expect(response.code).to eq("200")
        users = Set.new(JSON.parse(response.body)["users"])
        expected = Set.new(%w[cheetoh donskoy khaomanee nebelung russianblue])
        expect(users).to eq(expected)
      end
    end
  end

  context "GitHub team membership" do
    context "with changes" do
      it "invalidates the cache and reloads from the API" do
        expect(@result.stderr).to match(log("DEBUG", "Loading GitHub team github.fake:meowsister/employees from cache"))
        expect(@result.stderr).to match(log("DEBUG", Regexp.escape("Loaded cn=employees,ou=meowsister,ou=GitHub,dc=github,dc=fake (id=-1) with 8 member(s)")))
        expect(@result.stderr).to match(log("DEBUG", "Invalidating cache entry for cn=employees,ou=meowsister,ou=GitHub,dc=github,dc=fake"))
        expect(@result.stderr).to match(log("DEBUG", Regexp.escape("members(cn=employees,ou=meowsister,ou=GitHub,dc=github,dc=fake): DN has been marked invalid in cache")))
        expect(@result.stderr).to match(log("DEBUG", "Loading GitHub team github.fake:meowsister/employees$"))
        expect(@result.stderr).to match(log("DEBUG", Regexp.escape("Loaded cn=employees,ou=meowsister,ou=GitHub,dc=github,dc=fake (id=4) with 8 member(s)")))
      end

      it "detects and applies the correct changes" do
        expect(@result.stderr).to match(log("INFO", "CHANGE cn=employees,ou=meowsister,ou=GitHub,dc=github,dc=fake in github"))
        # There are 2 removals but 1 of these (ojosazules) is removed from the organization so really there
        # is just 1 call to the API to remove a user.
        expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_team(user=mainecoon, org=meowsister, team_id=4)")))
        expect(@result.stderr).to match(log("DEBUG", Regexp.escape('validate_team_id_and_slug!(4, "employees")')))
        expect(@result.stderr).to match(log("DEBUG", Regexp.escape("sync_team(employees=4): Added 0, removed 1")))
        expect(@result.stderr).to match(log("DEBUG", "APPLY: Updating GitHub team cn=employees,ou=meowsister,ou=GitHub,dc=github,dc=fake"))
      end

      it "sets the team membership correctly" do
        result = github_http_get("/teams/4/members")
        expect(result.code).to eq("200")
        obj = JSON.parse(result.body)
        expect(obj.map { |item| item["login"] }.sort).to eq(%w[nebelung cheetoh khaomanee blackmanx russianblue ragamuffin].sort)
      end
    end

    context "with out-of-sync data" do
      it "invalidates the cache and reloads from the API" do
        expect(@result.stderr).to match(log("DEBUG", "Loading GitHub team github.fake:meowsister/colonel-meow from cache"))
        expect(@result.stderr).to match(log("DEBUG", Regexp.escape("Loaded cn=colonel-meow,ou=meowsister,ou=GitHub,dc=github,dc=fake (id=-1) with 5 member(s)")))
        expect(@result.stderr).to match(log("DEBUG", "Invalidating cache entry for cn=colonel-meow,ou=meowsister,ou=GitHub,dc=github,dc=fake"))
        expect(@result.stderr).to match(log("DEBUG", Regexp.escape("members(cn=colonel-meow,ou=meowsister,ou=GitHub,dc=github,dc=fake): DN has been marked invalid in cache")))
        expect(@result.stderr).to match(log("DEBUG", "Loading GitHub team github.fake:meowsister/colonel-meow$"))
        expect(@result.stderr).to match(log("DEBUG", Regexp.escape("Loaded cn=colonel-meow,ou=meowsister,ou=GitHub,dc=github,dc=fake (id=6) with 4 member(s)")))
      end

      it "applies the change it believes is valid while skipping change due to cache inaccuracy" do
        expect(@result.stderr).to match(log("INFO", "CHANGE cn=colonel-meow,ou=meowsister,ou=GitHub,dc=github,dc=fake in github"))
        # The one delete is due to a user being removed from the organization, so when the code goes to remove
        # that user, the user is not on the team anymore. As such a warning is thrown.
        expect(@result.stderr).to match(log("DEBUG", Regexp.escape("sync_team(colonel-meow=6): Added 0, removed 0")))
        expect(@result.stderr).to match(log("WARN", "DID NOT APPLY: Changes not needed to cn=colonel-meow,ou=meowsister,ou=GitHub,dc=github,dc=fake"))
      end

      it "leaves the team membership alone" do
        result = github_http_get("/teams/6/members")
        expect(result.code).to eq("200")
        obj = JSON.parse(result.body)
        expect(obj.map { |item| item["login"] }.sort).to eq(%w[nebelung cheetoh khaomanee].sort)
      end
    end

    context "with no changes" do
      it "uses only the cache and does not hit the API" do
        expect(@result.stderr).to match(log("DEBUG", "Loading GitHub team github.fake:meowsister/grumpy-cat from cache"))
        expect(@result.stderr).to match(log("DEBUG", Regexp.escape("Loaded cn=grumpy-cat,ou=meowsister,ou=GitHub,dc=github,dc=fake (id=-1) with 4 member(s)")))
        expect(@result.stderr).not_to match(log("DEBUG", "Invalidating cache entry for cn=grumpy-cat,ou=meowsister,ou=GitHub,dc=github,dc=fake"))
        expect(@result.stderr).not_to match(log("DEBUG", Regexp.escape("members(cn=grumpy-cat,ou=meowsister,ou=GitHub,dc=github,dc=fake): DN has been marked invalid in cache")))
        expect(@result.stderr).not_to match(log("DEBUG", "Loading GitHub team github.fake:meowsister/grumpy-cat$"))
        expect(@result.stderr).not_to match(log("DEBUG", Regexp.escape("Loaded cn=grumpy-cat,ou=meowsister,ou=GitHub,dc=github,dc=fake (id=5)")))
      end

      it "detects that there are no changes" do
        expect(@result.stderr).to match(log("DEBUG", "UNCHANGED: No GitHub team changes for github:cn=grumpy-cat,ou=meowsister,ou=GitHub,dc=github,dc=fake"))
      end

      it "leaves the team membership alone" do
        result = github_http_get("/teams/5/members")
        expect(result.code).to eq("200")
        obj = JSON.parse(result.body)
        expect(obj.map { |item| item["login"] }.sort).to eq(%w[blackmanx mainecoon ragamuffin russianblue].sort)
      end
    end
  end
end
