# frozen_string_literal: true

require_relative "spec_helper"

describe Entitlements do
  context "with invitation feature flag" do
    before(:all) do
      admin = %w[blackmanx mainecoon peterbald]
      github_http_put("/entitlements-app-acceptance/orgs/admin", { "users" => admin })

      members = %w[ojosazules cyprus chausie khaomanee ragamuffin minskin nebelung]
      github_http_put("/entitlements-app-acceptance/orgs/member", { "users" => members })

      github_http_put("/entitlements-app-acceptance/pending", { "users" => [] })

      @result = run("github_org_ff_invite", ["--debug"])
    end

    it "returns success" do
      expect(@result.success?).to eq(true)
    end

    it "prints nothing on STDOUT" do
      expect(@result.stdout).to eq("")
    end

    it "prints appropriate messages" do
      expect(@result.stderr).to match(log("DEBUG", "GitHubOrg github-org:member: Feature `remove` disabled. Not removing 3 people: minskin, nebelung, ragamuffin."))
      expect(@result.stderr).to match(log("INFO", "CHANGE cn=admin,ou=meowsister-org,ou=GitHub,dc=github,dc=fake in github-org"))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  + korat")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - peterbald")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  + cyprus")))
      expect(@result.stderr).to match(log("INFO", "CHANGE cn=member,ou=meowsister-org,ou=GitHub,dc=github,dc=fake in github-org"))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  + DONSKoy")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  + russianblue")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  + cheetoh")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  + peterbald")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - cyprus")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=korat, org=meowsister, role=admin)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=russianblue, org=meowsister, role=member)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=cheetoh, org=meowsister, role=member)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=peterbald, org=meowsister, role=member)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=cyprus, org=meowsister, role=admin)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("sync(admin): Added 2, removed 0")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("sync(member): Added 4, removed 0")))
    end

    it "updates GitHub organization membership for admins" do
      response = github_http_get("/entitlements-app-acceptance/orgs/admin")
      expect(response.code).to eq("200")
      users = Set.new(JSON.parse(response.body)["users"])
      expected = Set.new(%w[blackmanx korat mainecoon cyprus])
      expect(users).to eq(expected)
    end

    it "updates GitHub organization membership for members" do
      response = github_http_get("/entitlements-app-acceptance/orgs/member")
      expect(response.code).to eq("200")
      users = Set.new(JSON.parse(response.body)["users"])
      expected = Set.new(%w[ojosazules donskoy chausie ragamuffin minskin khaomanee cheetoh nebelung peterbald russianblue])
      expect(users).to eq(expected)
    end
  end

  context "with remove feature flag" do
    before(:all) do
      admin = %w[blackmanx mainecoon peterbald]
      github_http_put("/entitlements-app-acceptance/orgs/admin", { "users" => admin })

      members = %w[ojosazules cyprus chausie khaomanee ragamuffin minskin nebelung]
      github_http_put("/entitlements-app-acceptance/orgs/member", { "users" => members })

      github_http_put("/entitlements-app-acceptance/pending", { "users" => [] })

      @result = run("github_org_ff_remove", ["--debug"])
    end

    it "returns success" do
      expect(@result.success?).to eq(true)
    end

    it "prints nothing on STDOUT" do
      expect(@result.stdout).to eq("")
    end

    it "prints appropriate messages" do
      expect(@result.stderr).to match(log("DEBUG", "GitHubOrg github-org:admin: Feature `invite` disabled. Not inviting 1 person: korat."))
      expect(@result.stderr).to match(log("DEBUG", "GitHubOrg github-org:member: Feature `invite` disabled. Not inviting 3 people: DONSKoy, cheetoh, russianblue."))
      expect(@result.stderr).to match(log("INFO", "CHANGE cn=admin,ou=meowsister-org,ou=GitHub,dc=github,dc=fake in github-org"))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - peterbald")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  + cyprus")))
      expect(@result.stderr).to match(log("INFO", "CHANGE cn=member,ou=meowsister-org,ou=GitHub,dc=github,dc=fake in github-org"))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - nebelung")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - ragamuffin")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  + peterbald")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - cyprus")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - minskin")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=cyprus, org=meowsister, role=admin)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=nebelung, org=meowsister)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=ragamuffin, org=meowsister)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=minskin, org=meowsister)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("sync(admin): Added 1, removed 0")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("sync(member): Added 1, removed 3")))
    end

    it "updates GitHub organization membership for admins" do
      response = github_http_get("/entitlements-app-acceptance/orgs/admin")
      expect(response.code).to eq("200")
      users = Set.new(JSON.parse(response.body)["users"])
      expected = Set.new(%w[blackmanx mainecoon cyprus])
      expect(users).to eq(expected)
    end

    it "updates GitHub organization membership for members" do
      response = github_http_get("/entitlements-app-acceptance/orgs/member")
      expect(response.code).to eq("200")
      users = Set.new(JSON.parse(response.body)["users"])
      expected = Set.new(%w[ojosazules chausie khaomanee peterbald])
      expect(users).to eq(expected)
    end
  end

  context "with neither remove nor invite feature flag" do
    before(:all) do
      admin = %w[blackmanx mainecoon peterbald]
      github_http_put("/entitlements-app-acceptance/orgs/admin", { "users" => admin })

      members = %w[ojosazules cyprus chausie khaomanee ragamuffin minskin nebelung]
      github_http_put("/entitlements-app-acceptance/orgs/member", { "users" => members })

      github_http_put("/entitlements-app-acceptance/pending", { "users" => [] })

      @result = run("github_org_ff_none", ["--debug"])
    end

    it "returns success" do
      expect(@result.success?).to eq(true)
    end

    it "prints nothing on STDOUT" do
      expect(@result.stdout).to eq("")
    end

    it "prints appropriate messages" do
      expect(@result.stderr).to match(log("DEBUG", "GitHubOrg github-org:member: Feature `remove` disabled. Not removing 3 people: minskin, nebelung, ragamuffin."))
      expect(@result.stderr).to match(log("DEBUG", "GitHubOrg github-org:admin: Feature `invite` disabled. Not inviting 1 person: korat."))
      expect(@result.stderr).to match(log("DEBUG", "GitHubOrg github-org:member: Feature `invite` disabled. Not inviting 3 people: DONSKoy, cheetoh, russianblue."))
      expect(@result.stderr).to match(log("INFO", "CHANGE cn=admin,ou=meowsister-org,ou=GitHub,dc=github,dc=fake in github-org"))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - peterbald")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  + cyprus")))
      expect(@result.stderr).to match(log("INFO", "CHANGE cn=member,ou=meowsister-org,ou=GitHub,dc=github,dc=fake in github-org"))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  + peterbald")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - cyprus")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=cyprus, org=meowsister, role=admin)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("sync(admin): Added 1, removed 0")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("sync(member): Added 1, removed 0")))
    end

    it "updates GitHub organization membership for admins" do
      response = github_http_get("/entitlements-app-acceptance/orgs/admin")
      expect(response.code).to eq("200")
      users = Set.new(JSON.parse(response.body)["users"])
      expected = Set.new(%w[blackmanx mainecoon cyprus])
      expect(users).to eq(expected)
    end

    it "updates GitHub organization membership for members" do
      response = github_http_get("/entitlements-app-acceptance/orgs/member")
      expect(response.code).to eq("200")
      users = Set.new(JSON.parse(response.body)["users"])
      expected = Set.new(%w[ojosazules minskin chausie khaomanee peterbald ragamuffin nebelung])
      expect(users).to eq(expected)
    end
  end

  context "with users as members who were offboarded" do
    before(:all) do
      admin = %w[blackmanx mainecoon peterbald offboarded1 offboarded2]
      github_http_put("/entitlements-app-acceptance/orgs/admin", { "users" => admin })

      members = %w[ojosazules cyprus chausie khaomanee ragamuffin minskin nebelung offboarded3]
      github_http_put("/entitlements-app-acceptance/orgs/member", { "users" => members })

      github_http_put("/entitlements-app-acceptance/pending", { "users" => [] })

      @result = run("github_org_ff_remove", ["--debug"])
    end

    it "returns success" do
      expect(@result.success?).to eq(true)
    end

    it "prints nothing on STDOUT" do
      expect(@result.stdout).to eq("")
    end

    it "prints appropriate messages" do
      expect(@result.stderr).to match(log("DEBUG", "GitHubOrg github-org:admin: Feature `invite` disabled. Not inviting 1 person: korat."))
      expect(@result.stderr).to match(log("DEBUG", "GitHubOrg github-org:member: Feature `invite` disabled. Not inviting 3 people: DONSKoy, cheetoh, russianblue."))
      expect(@result.stderr).to match(log("INFO", "CHANGE cn=admin,ou=meowsister-org,ou=GitHub,dc=github,dc=fake in github-org"))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - offboarded1")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - offboarded2")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - peterbald")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  + cyprus")))
      expect(@result.stderr).to match(log("INFO", "CHANGE cn=member,ou=meowsister-org,ou=GitHub,dc=github,dc=fake in github-org"))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - nebelung")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - ragamuffin")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - offboarded3")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  + peterbald")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - cyprus")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - minskin")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=cyprus, org=meowsister, role=admin)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=nebelung, org=meowsister)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=offboarded1, org=meowsister)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=offboarded2, org=meowsister)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=offboarded3, org=meowsister)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=ragamuffin, org=meowsister)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=minskin, org=meowsister)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("sync(admin): Added 1, removed 2")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("sync(member): Added 1, removed 4")))
    end

    it "updates GitHub organization membership for admins" do
      response = github_http_get("/entitlements-app-acceptance/orgs/admin")
      expect(response.code).to eq("200")
      users = Set.new(JSON.parse(response.body)["users"])
      expected = Set.new(%w[blackmanx mainecoon cyprus])
      expect(users).to eq(expected)
    end

    it "updates GitHub organization membership for members" do
      response = github_http_get("/entitlements-app-acceptance/orgs/member")
      expect(response.code).to eq("200")
      users = Set.new(JSON.parse(response.body)["users"])
      expected = Set.new(%w[ojosazules chausie khaomanee peterbald])
      expect(users).to eq(expected)
    end
  end

  context "with pending members who were offboarded" do
    before(:all) do
      admin = %w[blackmanx peterbald offboarded2]
      github_http_put("/entitlements-app-acceptance/orgs/admin", { "users" => admin })

      members = %w[ojosazules cyprus chausie khaomanee ragamuffin minskin nebelung]
      github_http_put("/entitlements-app-acceptance/orgs/member", { "users" => members })

      github_http_put("/entitlements-app-acceptance/pending", { "users" => %w[mainecoon offboarded1 offboarded3] })

      @result = run("github_org_ff_remove", ["--debug"])
    end

    it "returns success" do
      expect(@result.success?).to eq(true)
    end

    it "prints nothing on STDOUT" do
      expect(@result.stdout).to eq("")
    end

    it "prints appropriate messages" do
      expect(@result.stderr).to match(log("DEBUG", "GitHubOrg github-org:admin: Feature `invite` disabled. Not inviting 1 person: korat."))
      expect(@result.stderr).to match(log("DEBUG", "GitHubOrg github-org:member: Feature `invite` disabled. Not inviting 3 people: DONSKoy, cheetoh, russianblue."))
      expect(@result.stderr).to match(log("INFO", "CHANGE cn=admin,ou=meowsister-org,ou=GitHub,dc=github,dc=fake in github-org"))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - offboarded1")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - offboarded2")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - peterbald")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  + cyprus")))
      expect(@result.stderr).to match(log("INFO", "CHANGE cn=member,ou=meowsister-org,ou=GitHub,dc=github,dc=fake in github-org"))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - nebelung")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - ragamuffin")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - offboarded3")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  + peterbald")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - cyprus")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - minskin")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=cyprus, org=meowsister, role=admin)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=nebelung, org=meowsister)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=offboarded1, org=meowsister)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=offboarded2, org=meowsister)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=offboarded3, org=meowsister)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=ragamuffin, org=meowsister)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=minskin, org=meowsister)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("sync(admin): Added 1, removed 1")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("sync(member): Added 1, removed 5")))
    end

    it "updates GitHub organization membership for admins" do
      response = github_http_get("/entitlements-app-acceptance/orgs/admin")
      expect(response.code).to eq("200")
      users = Set.new(JSON.parse(response.body)["users"])
      expected = Set.new(%w[blackmanx cyprus])
      expect(users).to eq(expected)
    end

    it "updates GitHub organization membership for members" do
      response = github_http_get("/entitlements-app-acceptance/orgs/member")
      expect(response.code).to eq("200")
      users = Set.new(JSON.parse(response.body)["users"])
      expected = Set.new(%w[ojosazules chausie khaomanee peterbald])
      expect(users).to eq(expected)
    end
  end

  context "not making changes to specified users" do
    before(:all) do
      admin = %w[blackmanx mainecoon peterbald monalisa]
      github_http_put("/entitlements-app-acceptance/orgs/admin", { "users" => admin })

      members = %w[ojosazules cyprus chausie khaomanee ragamuffin minskin cheetoh nebelung]
      github_http_put("/entitlements-app-acceptance/orgs/member", { "users" => members })

      github_http_put("/entitlements-app-acceptance/pending", { "users" => [] })

      @result = run("github_org_ignore", ["--debug"])
    end

    it "returns success" do
      expect(@result.success?).to eq(true)
    end

    it "prints nothing on STDOUT" do
      expect(@result.stdout).to eq("")
    end

    it "prints expected change messages" do
      expect(@result.stderr).to match(log("INFO", "CHANGE cn=admin,ou=meowsister-org,ou=GitHub,dc=github,dc=fake in github-org"))
      expect(@result.stderr).to match(log("INFO", "CHANGE cn=member,ou=meowsister-org,ou=GitHub,dc=github,dc=fake in github-org"))

      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  + cyprus")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  + DONSKoy")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  + russianblue")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - nebelung")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - ragamuffin")))
    end

    it "does not print messages for ignored users" do
      expect(@result.stderr).not_to match(log("INFO", Regexp.escape(".  + korat")))
      expect(@result.stderr).not_to match(log("INFO", Regexp.escape(".  - monalisa")))
      expect(@result.stderr).not_to match(log("INFO", Regexp.escape(".  - peterbald")))
      expect(@result.stderr).not_to match(log("INFO", Regexp.escape(".  + peterbald")))
      expect(@result.stderr).not_to match(log("INFO", Regexp.escape(".  - minskin")))
    end

    it "prints expected action messages" do
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=donskoy, org=meowsister, role=member)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=russianblue, org=meowsister, role=member)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=cyprus, org=meowsister, role=admin)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=nebelung, org=meowsister)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=ragamuffin, org=meowsister)")))

      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("sync(admin): Added 1, removed 0")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("sync(member): Added 2, removed 2")))
    end

    it "does not print action messages for ignored users" do
      expect(@result.stderr).not_to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=korat")))
      expect(@result.stderr).not_to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=peterbald")))
      expect(@result.stderr).not_to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=minskin, org=meowsister)")))
    end

    it "updates GitHub organization membership for admins" do
      response = github_http_get("/entitlements-app-acceptance/orgs/admin")
      expect(response.code).to eq("200")
      users = Set.new(JSON.parse(response.body)["users"])
      expected = Set.new(%w[blackmanx monalisa peterbald mainecoon cyprus])
      expect(users).to eq(expected)
    end

    it "updates GitHub organization membership for members" do
      response = github_http_get("/entitlements-app-acceptance/orgs/member")
      expect(response.code).to eq("200")
      users = Set.new(JSON.parse(response.body)["users"])
      expected = Set.new(%w[ojosazules chausie khaomanee minskin donskoy russianblue cheetoh])
      expect(users).to eq(expected)
    end
  end

  context "with pending members suppressed from invitation list" do
    before(:all) do
      admin = %w[blackmanx mainecoon peterbald]
      github_http_put("/entitlements-app-acceptance/orgs/admin", { "users" => admin })

      members = %w[ojosazules cyprus chausie khaomanee ragamuffin minskin nebelung]
      github_http_put("/entitlements-app-acceptance/orgs/member", { "users" => members })

      github_http_put("/entitlements-app-acceptance/pending", { "users" => %w[korat donskoy] })

      @result = run("github_org_ff_invite", ["--debug"])
    end

    it "returns success" do
      expect(@result.success?).to eq(true)
    end

    it "prints nothing on STDOUT" do
      expect(@result.stdout).to eq("")
    end

    it "prints appropriate messages" do
      expect(@result.stderr).to match(log("DEBUG", "GitHubOrg github-org:member: Feature `remove` disabled. Not removing 3 people: minskin, nebelung, ragamuffin."))
      expect(@result.stderr).to match(log("INFO", "CHANGE cn=admin,ou=meowsister-org,ou=GitHub,dc=github,dc=fake in github-org"))
      expect(@result.stderr).not_to match(log("INFO", Regexp.escape(".  + korat")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - peterbald")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  + cyprus")))
      expect(@result.stderr).to match(log("INFO", "CHANGE cn=member,ou=meowsister-org,ou=GitHub,dc=github,dc=fake in github-org"))
      expect(@result.stderr).not_to match(log("INFO", Regexp.escape(".  + DONSKoy")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  + russianblue")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  + cheetoh")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  + peterbald")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - cyprus")))
      expect(@result.stderr).not_to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=korat, org=meowsister, role=admin)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=russianblue, org=meowsister, role=member)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=cheetoh, org=meowsister, role=member)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=peterbald, org=meowsister, role=member)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=cyprus, org=meowsister, role=admin)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("sync(admin): Added 1, removed 0")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("sync(member): Added 3, removed 0")))
    end

    it "updates GitHub organization membership for admins" do
      response = github_http_get("/entitlements-app-acceptance/orgs/admin")
      expect(response.code).to eq("200")
      users = Set.new(JSON.parse(response.body)["users"])
      expected = Set.new(%w[blackmanx mainecoon cyprus])
      expect(users).to eq(expected)
    end

    it "updates GitHub organization membership for members" do
      response = github_http_get("/entitlements-app-acceptance/orgs/member")
      expect(response.code).to eq("200")
      users = Set.new(JSON.parse(response.body)["users"])
      expected = Set.new(%w[ojosazules chausie ragamuffin minskin khaomanee cheetoh nebelung peterbald russianblue])
      expect(users).to eq(expected)
    end
  end

  context "with pending members" do
    before(:all) do
      admin = %w[blackmanx mainecoon peterbald offboarded3]
      github_http_put("/entitlements-app-acceptance/orgs/admin", { "users" => admin })

      members = %w[khaomanee ragamuffin nebelung napoleon]
      github_http_put("/entitlements-app-acceptance/orgs/member", { "users" => members })

      pending = %w[ojosazules cyprus chausie offboarded1 offboarded2]
      github_http_put("/entitlements-app-acceptance/pending", { "users" => pending })

      @result = run("github_org_pending", ["--debug"])
    end

    it "returns success" do
      expect(@result.success?).to eq(true)
    end

    it "prints nothing on STDOUT" do
      expect(@result.stdout).to eq("")
    end

    it "prints appropriate messages" do
      expect(@result.stderr).to match(log("INFO", Regexp.escape("Successfully applied 3 change(s)!")))
    end

    it "does not print messages for existing but pending members" do
      expect(@result.stderr).not_to match(/chausie/i)
      expect(@result.stderr).not_to match(/cyprus/i)
    end

    it "logs messages for updating membership for admins" do
      expect(@result.stderr).to match(log("INFO", "CHANGE cn=admin,ou=meowsister-org,ou=GitHub,dc=github,dc=fake in github-org"))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  + korat")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - offboarded3")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - peterbald")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  + RAGAMUFFIn")))

      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=korat, org=meowsister, role=admin)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=ragamuffin, org=meowsister, role=admin)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=offboarded3, org=meowsister)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("sync(admin): Added 2, removed 1")))

      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("APPLY: Updating GitHub organization cn=admin,ou=meowsister-org,ou=GitHub,dc=github,dc=fake")))
    end

    it "updates GitHub organization membership for admins" do
      response = github_http_get("/entitlements-app-acceptance/orgs/admin")
      expect(response.code).to eq("200")
      users = Set.new(JSON.parse(response.body)["users"])
      expected = Set.new(%w[blackmanx korat mainecoon ragamuffin])
      expect(users).to eq(expected)
    end

    it "logs messages for updating membership for members" do
      expect(@result.stderr).to match(log("INFO", "CHANGE cn=member,ou=meowsister-org,ou=GitHub,dc=github,dc=fake in github-org"))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  + minskin")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - napoleon")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - nebelung")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - offboarded1")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - offboarded2")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  + peterbald")))
      expect(@result.stderr).to match(log("INFO", Regexp.escape(".  - RAGAMUFFIn")))

      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=minskin, org=meowsister, role=member)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=peterbald, org=meowsister, role=member)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=napoleon, org=meowsister)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=nebelung, org=meowsister)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=offboarded1, org=meowsister)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=offboarded2, org=meowsister)")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("sync(member): Added 2, removed 4")))

      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("APPLY: Updating GitHub organization cn=member,ou=meowsister-org,ou=GitHub,dc=github,dc=fake")))
    end

    it "updates GitHub organization membership for members" do
      response = github_http_get("/entitlements-app-acceptance/orgs/member")
      expect(response.code).to eq("200")
      users = Set.new(JSON.parse(response.body)["users"])
      expected = Set.new(%w[peterbald khaomanee minskin])
      expect(users).to eq(expected)
    end

    it "removes pending members while preserving existing invitees" do
      response = github_http_get("/entitlements-app-acceptance/pending")
      expect(response.code).to eq("200")
      users = Set.new(JSON.parse(response.body)["users"])
      expected = Set.new(%w[ojosazules cyprus chausie])
      expect(users).to eq(expected)
    end

    it "logs messages for adjusting team membership" do
      expect(@result.stderr).to match(log("INFO", "CHANGE cn=employees,ou=meowsister,ou=GitHub,dc=github,dc=fake in github"))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("sync_team(employees=4): Added 3, removed 1")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake add_user_to_team(user=khaomanee, org=meowsister")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake add_user_to_team(user=peterbald, org=meowsister")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake add_user_to_team(user=ragamuffin, org=meowsister")))
      expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_team(user=mainecoon, org=meowsister")))
    end

    it "updates team membership for organization admins and members" do
      result = github_http_get("/teams/4/members")
      expect(result.code).to eq("200")
      obj = JSON.parse(result.body)
      # ojosazules was not pending in `modify_and_delete` and became
      # part of the team there, and should not have been removed by being skipped.
      answer = %w[blackmanx ragamuffin khaomanee ojosazules peterbald]
      expect(obj.map { |item| item["login"] }.sort).to eq(answer.sort)
    end

    it "does not adjust team membership for users who are pending or not members" do
      expect(@result.stderr).not_to match(log("DEBUG", Regexp.escape("github.fake add_user_to_team(user=chausie, org=meowsister")))
      expect(@result.stderr).not_to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_team(user=nebelung, org=meowsister")))
      expect(@result.stderr).not_to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_team(user=ojosazules, org=meowsister")))
    end

    it "skips people whose invitation is pending" do
      expect(@result.stderr).not_to match(log("INFO", Regexp.escape(".  + balinese")))
      expect(@result.stderr).not_to match(log("INFO", Regexp.escape(".  + chausie")))
      expect(@result.stderr).not_to match(log("INFO", Regexp.escape(".  + cyprus")))
      expect(@result.stderr).not_to match(log("INFO", Regexp.escape(".  + desertlynx")))
    end
  end
end
