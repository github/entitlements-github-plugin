# frozen_string_literal: true

require_relative "spec_helper"

describe Entitlements do
  before(:all) do
    @result = run("modify_and_delete_lockout", ["--debug"])
  end

  it "returns success" do
    expect(@result.success?).to eq(true)
  end

  it "prints nothing on STDOUT" do
    expect(@result.stdout).to eq("")
  end

  it "logs appropriate messages to STDERR for user being removed" do
    expect(@result.stderr).to match(log("INFO", "CHANGE cn=app-aws-primary-admins,ou=Entitlements,ou=Groups,dc=kittens,dc=net in entitlements"))
    expect(@result.stderr).to match(log("INFO", ".  - cheetoh"))
    expect(@result.stderr).to match(log("INFO", "CHANGE cn=keyboard-cat,ou=Pizza_Teams,ou=Groups,dc=kittens,dc=net in pizza_teams"))
    expect(@result.stderr).to match(log("INFO", "CHANGE cn=colonel-meow,ou=Pizza_Teams,ou=Groups,dc=kittens,dc=net in pizza_teams"))
    expect(@result.stderr).to match(log("INFO", "CHANGE cn=member,ou=meowsister-org,ou=GitHub,dc=github,dc=fake in github-org"))
    expect(@result.stderr).to match(log("INFO", "CHANGE cn=employees,ou=meowsister,ou=GitHub,dc=github,dc=fake"))
    expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=cheetoh, org=meowsister)")))
  end

  it "has the correct change count" do
    # Hey there! If you are here because this test is failing, please don't blindly update the number.
    # Figure out what change you made that caused this number to increase or decrease, and add log checks
    # for it above.
    expect(@result.stderr).to match(log("INFO", "Successfully applied 7 change\\(s\\)!"))
  end

  it "does not apply team changes that are unnecessary due to removal from org" do
    expect(@result.stderr).to match(log("WARN", "DID NOT APPLY: Changes not needed to cn=employees,ou=meowsister,ou=GitHub,dc=github,dc=fake"))
    expect(@result.stderr).to match(log("DEBUG", Regexp.escape("sync_team(employees=4): Added 0, removed 0")))
    expect(@result.stderr).to match(log("WARN", "DID NOT APPLY: Changes not needed to cn=colonel-meow,ou=meowsister,ou=GitHub,dc=github,dc=fake"))
    expect(@result.stderr).to match(log("DEBUG", Regexp.escape("sync_team(colonel-meow=6): Added 0, removed 0")))
  end

  it "implements adjustment to group containing the locked out user" do
    expect(members("cn=app-aws-primary-admins,ou=Entitlements,ou=Groups,dc=kittens,dc=net")).to eq(people_set(%w[ojosazules nebelung khaomanee chausie cyprus]))
  end

  it "creates and populates the lockout group" do
    expect(members("cn=locked-out,ou=Pizza_Teams,ou=Groups,dc=kittens,dc=net")).to eq(people_set(%w[cheetoh]))
  end

  it "updates GitHub organization membership for members" do
    response = github_http_get("/entitlements-app-acceptance/orgs/member")
    expect(response.code).to eq("200")
    users = Set.new(JSON.parse(response.body)["users"])
    expected = Set.new(["ojosazules", "cyprus", "donskoy", "chausie", "ragamuffin", "minskin", "khaomanee", "nebelung"])
    expect(users).to eq(expected)
  end

  it "implements GitHub team removal" do
    result = github_http_get("/teams/4/members")
    expect(result.code).to eq("200")
    obj = JSON.parse(result.body)
    expect(obj.map { |item| item["login"] }.sort).to eq(%w[nebelung ojosazules blackmanx ragamuffin mainecoon].sort)
  end

  it "implements shellentitlements changes for the locked out user" do
    user = ldap_entry("uid=cheetoh,ou=People,dc=kittens,dc=net")
    expect(user[:shellentitlements]).to eq([])
  end
end
