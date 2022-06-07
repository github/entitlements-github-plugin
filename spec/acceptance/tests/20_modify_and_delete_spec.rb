# frozen_string_literal: true

require_relative "spec_helper"

describe Entitlements do
  before(:all) do
    @result = run("modify_and_delete", ["--debug"])
  end

  it "returns success" do
    expect(@result.success?).to eq(true)
  end

  it "prints nothing on STDOUT" do
    expect(@result.stdout).to eq("")
  end

  it "logs appropriate debug messages to STDERR" do
    expect(@result.stderr).to match(log("DEBUG", "Loading all groups for ou=Entitlements,ou=Groups,dc=kittens,dc=net"))
    expect(@result.stderr).to match(log("DEBUG", "Loading all groups for ou=Pizza_Teams,ou=Groups,dc=kittens,dc=net"))
    expect(@result.stderr).to match(log("DEBUG", "APPLY: Upserting cn=app-aws-primary-admins,ou=Entitlements,ou=Groups,dc=kittens,dc=net"))
    expect(@result.stderr).to match(log("DEBUG", "APPLY: Deleting cn=grumpy-cat,ou=Pizza_Teams,ou=Groups,dc=kittens,dc=net"))
    expect(@result.stderr).not_to match(log("DEBUG", "APPLY:.*cn=colonel-meow,ou=Pizza_Teams,ou=Groups,dc=kittens,dc=net"))
    expect(@result.stderr).to match(log("DEBUG", "OU create_if_missing: ou=foo-bar-app,ou=Entitlements,ou=Groups,dc=kittens,dc=net already exists"))
    expect(@result.stderr).to match(log("DEBUG", "OU create_if_missing: ou=kittens,ou=foo-bar-app,ou=Entitlements,ou=Groups,dc=kittens,dc=net needs to be created"))
  end

  it "logs appropriate messages for GitHub organization owner/member" do
    expect(@result.stderr).to match(log("DEBUG", Regexp.escape("Currently meowsister has 3 admin(s) and 8 member(s)")))
    expect(@result.stderr).to match(log("INFO", "CHANGE cn=admin,ou=meowsister-org,ou=GitHub,dc=github,dc=fake in github-org"))
    expect(@result.stderr).to match(log("INFO", "CHANGE cn=member,ou=meowsister-org,ou=GitHub,dc=github,dc=fake in github-org"))

    expect(@result.stderr).to match(log("DEBUG", Regexp.escape("sync(admin): Added 1, removed 0")))
    expect(@result.stderr).to match(log("DEBUG", "APPLY: Updating GitHub organization cn=admin,ou=meowsister-org,ou=GitHub,dc=github,dc=fake"))

    expect(@result.stderr).to match(log("DEBUG", Regexp.escape("sync(member): Added 2, removed 1")))
    expect(@result.stderr).to match(log("DEBUG", "APPLY: Updating GitHub organization cn=member,ou=meowsister-org,ou=GitHub,dc=github,dc=fake"))

    expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=peterbald, org=meowsister, role=admin)")))
    expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=ragamuffin, org=meowsister, role=member)")))
    expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake add_user_to_organization(user=minskin, org=meowsister, role=member)")))
    expect(@result.stderr).to match(log("DEBUG", Regexp.escape("github.fake remove_user_from_organization(user=russianblue, org=meowsister)")))
  end

  it "no longer complains about GitHub teams without an ID" do
    expect(@result.stderr).not_to match(/Enumerating all teams from GitHub org "meowsister" from github.fake/)
    expect(@result.stderr).not_to match(/Please add team_id=\d+ for team/)
  end

  it "logs appropriate informational messages to STDERR for memberOf" do
    expect(@result.stderr).to match(log("DEBUG", "Calculating memberOf attributes for configured groups"))
    expect(@result.stderr).not_to match(log("INFO", "Person blackmanx attribute change:"))
    expect(@result.stderr).to match(log("INFO", "Person russianblue attribute change:"))
    expect(@result.stderr).to match(log("INFO", ". MODIFY attribute shellentitlements:"))
    expect(@result.stderr).to match(log("INFO", '.  - "cn=baz,ou=GroupOfNames,ou=Entitlements,ou=Groups,dc=kittens,dc=net"'))
    expect(@result.stderr).to match(log("INFO", "Person RAGAMUFFIn attribute change:"))
    expect(@result.stderr).to match(log("INFO", ". (ADD|MODIFY) attribute shellentitlements:"))
    expect(@result.stderr).to match(log("INFO", '.  \\+ "cn=bar,ou=GroupOfNames,ou=Entitlements,ou=Groups,dc=kittens,dc=net"'))
    expect(@result.stderr).to match(log("INFO", '.  - "cn=sparkles,ou=GroupOfNames,ou=Entitlements,ou=Groups,dc=kittens,dc=net"'))
    expect(@result.stderr).to match(log("INFO", "Person mainecoon attribute change:"))
    expect(@result.stderr).to match(log("INFO", ". (ADD|MODIFY) attribute shellentitlements:"))
    expect(@result.stderr).to match(log("INFO", '.  \\+ "cn=bar,ou=GroupOfNames,ou=Entitlements,ou=Groups,dc=kittens,dc=net"'))
    expect(@result.stderr).to match(log("INFO", '.  \\+ "cn=baz,ou=GroupOfNames,ou=Entitlements,ou=Groups,dc=kittens,dc=net"'))
    expect(@result.stderr).not_to match(log("INFO", "Person foldex attribute change:"))
  end

  it "logs appropriate informational messages to STDERR" do
    expect(@result.stderr).to match(log("INFO", "CHANGE cn=app-aws-primary-admins,ou=Entitlements,ou=Groups,dc=kittens,dc=net in entitlements"))
    expect(@result.stderr).to match(log("INFO", ".  - blackmanx"))
    expect(@result.stderr).to match(log("INFO", "CHANGE cn=keyboard-cat,ou=Pizza_Teams,ou=Groups,dc=kittens,dc=net in pizza_teams"))
    expect(@result.stderr).to match(log("INFO", ".  - NEBELUNg"))
    expect(@result.stderr).to match(log("INFO", ".  - khaomanee"))
    expect(@result.stderr).to match(log("INFO", "DELETE cn=grumpy-cat,ou=Pizza_Teams,ou=Groups,dc=kittens,dc=net from pizza_teams"))
    expect(@result.stderr).to match(log("INFO", "DELETE cn=baz,ou=foo-bar-app,ou=Entitlements,ou=Groups,dc=kittens,dc=net from entitlements/foo-bar-app"))
    expect(@result.stderr).to match(log("INFO", "ADD cn=baz,ou=kittens,ou=foo-bar-app,ou=Entitlements,ou=Groups,dc=kittens,dc=net to entitlements/foo-bar-app/kittens"))
    expect(@result.stderr).to match(log("INFO", "ADD cn=contractors,ou=Pizza_Teams,ou=Groups,dc=kittens,dc=net to pizza_teams \\(Members: pixiebob\\)"))
    expect(@result.stderr).to match(log("INFO", "DELETE cn=sparkles,ou=GroupOfNames,ou=Entitlements,ou=Groups,dc=kittens,dc=net from entitlements/groupofnames"))
    expect(@result.stderr).to match(log("INFO", "DELETE cn=sparkles,ou=Mirror,ou=Entitlements,ou=Groups,dc=kittens,dc=net from entitlements/mirror"))
    expect(@result.stderr).not_to match(log("INFO", ".*cn=colonel-meow"))
  end

  it "logs messages due to an expiring entitlement being emptied" do
    expect(@result.stderr).to match(log("INFO", "CHANGE cn=expire-later,ou=Entitlements,ou=Groups,dc=kittens,dc=net in entitlements"))
    expect(@result.stderr).to match(log("INFO", ".  - NEBELUNg"))
    expect(@result.stderr).to match(log("INFO", ".  - blackmanx"))
  end

  it "has the correct change count" do
    # Hey there! If you are here because this test is failing, please don't blindly update the number.
    # Figure out what change you made that caused this number to increase or decrease, and add log checks
    # for it above.
    expect(@result.stderr).to match(log("INFO", "Successfully applied 28 change\\(s\\)!"))
  end

  it "has no 'DID NOT APPLY' warnings" do
    expect(@result.stderr).not_to match(log("WARN", "DID NOT APPLY"))
  end

  it "has no 'SKIP' messages" do
    expect(@result.stderr).not_to match(log("DEBUG", "SKIP"))
  end

  it "preserves the still-present LDAP groups" do
    expect(ldap_exist?("cn=app-aws-primary-admins,ou=Entitlements,ou=Groups,dc=kittens,dc=net")).to eq(true)
    expect(ldap_exist?("cn=colonel-meow,ou=Pizza_Teams,ou=Groups,dc=kittens,dc=net")).to eq(true)
  end

  it "creates the OU" do
    expect(ldap_exist?("ou=foo-bar-app,ou=Entitlements,ou=Groups,dc=kittens,dc=net")).to eq(true)
    expect(ldap_exist?("ou=kittens,ou=foo-bar-app,ou=Entitlements,ou=Groups,dc=kittens,dc=net")).to eq(true)
  end

  it "creates new LDAP group with proper contractors" do
    expect(ldap_exist?("cn=contractors,ou=Pizza_Teams,ou=Groups,dc=kittens,dc=net")).to eq(true)
    expected = %w[pixiebob]
    expect(members("cn=contractors,ou=Pizza_Teams,ou=Groups,dc=kittens,dc=net")).to eq(people_set(expected))
  end

  it "creates new LDAP group in the sub-OU" do
    expect(ldap_exist?("cn=baz,ou=kittens,ou=foo-bar-app,ou=Entitlements,ou=Groups,dc=kittens,dc=net")).to eq(true)
    expected = %w[blackmanx russianblue]
    expect(members("cn=baz,ou=kittens,ou=foo-bar-app,ou=Entitlements,ou=Groups,dc=kittens,dc=net")).to eq(people_set(expected))
  end

  it "deletes old LDAP group in the sub-OU" do
    expect(ldap_exist?("cn=baz,ou=foo-bar-app,ou=Entitlements,dc=kittens,dc=net")).to eq(false)
  end

  it "deletes the removed LDAP group" do
    expect(ldap_exist?("cn=grumpy-cat,ou=Pizza_Teams,ou=Groups,dc=kittens,dc=net")).to eq(false)
  end

  it "updates the recursive YAML-generated LDAP group with the expected members" do
    expected = %w[oJosazuLEs NEBELUNg khaomanee chausie cheetoh cyprus]
    expect(members("cn=app-aws-primary-admins,ou=Entitlements,ou=Groups,dc=kittens,dc=net")).to eq(people_set(expected))
  end

  it "leaves the YAML-generated LDAP group alone when unchanged" do
    expected = %w[oJosazuLEs NEBELUNg khaomanee chausie cheetoh cyprus]
    expect(members("cn=colonel-meow,ou=Pizza_Teams,ou=Groups,dc=kittens,dc=net")).to eq(people_set(expected))
  end

  it "adds the contractors group with the proper members" do
    expected = %w[pixiebob]
    expect(members("cn=contractors,ou=Pizza_Teams,ou=Groups,dc=kittens,dc=net")).to eq(people_set(expected))
  end

  it "does not add != members to defined group" do
    expect(members("cn=keyboard-cat,ou=Pizza_Teams,ou=Groups,dc=kittens,dc=net")).not_to include("uid=nebelung,ou=people,dc=kittens,dc=net")
    expect(members("cn=keyboard-cat,ou=Pizza_Teams,ou=Groups,dc=kittens,dc=net")).not_to include("uid=khaomanee,ou=people,dc=kittens,dc=net")
    expect(members("cn=keyboard-cat,ou=Pizza_Teams,ou=Groups,dc=kittens,dc=net")).to include("uid=cyprus,ou=people,dc=kittens,dc=net")
  end

  it "properly creates the new GroupOfNames group" do
    dn = "cn=bar,ou=GroupOfNames,ou=Entitlements,ou=Groups,dc=kittens,dc=net"

    result = ldap_entry(dn)
    expect(result).to be_a_kind_of(Net::LDAP::Entry)
    expect(result.dn).to eq(dn)

    expect(result[:cn]).to eq(["bar"])
    expect(result[:description]).to eq(["This is in a sub-ou"])
    expect(result[:owner]).to eq(["uid=emmy,ou=Service_Accounts,dc=kittens,dc=net"])

    expect(result[:objectclass]).to eq(["groupOfNames"])
    expect(result[:member].sort).to eq(["uid=RAGAMUFFIn,ou=People,dc=kittens,dc=net", "uid=mainecoon,ou=People,dc=kittens,dc=net"])
  end

  it "properly updates the modified GroupOfNames group" do
    dn = "cn=baz,ou=GroupOfNames,ou=Entitlements,ou=Groups,dc=kittens,dc=net"

    result = ldap_entry(dn)
    expect(result).to be_a_kind_of(Net::LDAP::Entry)
    expect(result.dn).to eq(dn)

    expect(result[:cn]).to eq(["baz"])
    expect(result[:description]).to eq(["This is in a sub-ou"])
    expect(result[:owner]).to eq(["uid=emmy,ou=Service_Accounts,dc=kittens,dc=net"])

    expect(result[:objectclass]).to eq(["groupOfNames"])
    expect(result[:member].sort).to eq(["uid=blackmanx,ou=People,dc=kittens,dc=net", "uid=mainecoon,ou=People,dc=kittens,dc=net"])
  end

  it "creates the new mirror group" do
    dn = "cn=bar,ou=Mirror,ou=Entitlements,ou=Groups,dc=kittens,dc=net"

    result = ldap_entry(dn)
    expect(result).to be_a_kind_of(Net::LDAP::Entry)
    expect(result.dn).to eq(dn)

    expect(result[:cn]).to eq(["bar"])
    expect(result[:description]).to eq(["This is in a sub-ou"])
    expect(result[:objectclass]).to eq(["posixGroup"])
    expect(result[:gidnumber]).to eq(["34567"])

    expected = %w[RAGAMUFFIn mainecoon]
    expect(members(dn)).to eq(people_set(expected))
  end

  it "properly updates the mirror group" do
    dn = "cn=baz,ou=Mirror,ou=Entitlements,ou=Groups,dc=kittens,dc=net"

    result = ldap_entry(dn)
    expect(result).to be_a_kind_of(Net::LDAP::Entry)
    expect(result.dn).to eq(dn)

    expect(result[:cn]).to eq(["baz"])
    expect(result[:description]).to eq(["This is in a sub-ou"])
    expect(result[:objectclass]).to eq(["posixGroup"])
    expect(result[:gidnumber]).to eq(["45678"])

    expected = %w[blackmanx mainecoon]
    expect(members(dn)).to eq(people_set(expected))
  end

  it "deletes the removed group from the source and the mirror" do
    expect(ldap_exist?("cn=sparkles,ou=GroupOfNames,ou=Entitlements,ou=Groups,dc=kittens,dc=net")).to eq(false)
    expect(ldap_exist?("cn=sparkles,ou=Mirror,ou=Entitlements,ou=Groups,dc=kittens,dc=net")).to eq(false)
  end

  it "keeps the now-empty groups as self-referencing" do
    dn1 = "cn=empty-but-ok,ou=Pizza_Teams,ou=Groups,dc=kittens,dc=net"
    expect(ldap_exist?(dn1)).to eq(true)
    expect(members(dn1)).to eq(Set.new([dn1.downcase]))

    dn2 = "cn=empty-but-ok,ou=Entitlements,ou=Groups,dc=kittens,dc=net"
    expect(ldap_exist?(dn2)).to eq(true)
    expect(members(dn2)).to eq(Set.new([dn2.downcase]))
  end

  it "adds the no-longer-empty group" do
    expect(ldap_exist?("cn=empty-but-ok-2,ou=Pizza_Teams,ou=Groups,dc=kittens,dc=net")).to eq(true)
    expect(members("cn=empty-but-ok-2,ou=Pizza_Teams,ou=Groups,dc=kittens,dc=net")).to eq(people_set(%w[blackmanx]))
  end

  it "has the correct membership for groups based on empty group testing" do
    expect(members("cn=empty-but-ok-2,ou=Entitlements,ou=Groups,dc=kittens,dc=net")).to eq(people_set(%w[RAGAMUFFIn]))
    expect(members("cn=empty-but-ok-3,ou=Entitlements,ou=Groups,dc=kittens,dc=net")).to eq(people_set(%w[RAGAMUFFIn blackmanx]))
  end

  it "updates shellentitlements for a user with no more" do
    user = ldap_entry("uid=russianblue,ou=People,dc=kittens,dc=net")
    expect(user[:cn]).to eq(["russianblue"])
    expect(user[:shellentitlements]).to eq([])
  end

  it "updates shellentitlements for an existing user" do
    user = ldap_entry("uid=RAGAMUFFIn,ou=People,dc=kittens,dc=net")
    expect(user[:shellentitlements]).to eq(["cn=bar,ou=GroupOfNames,ou=Entitlements,ou=Groups,dc=kittens,dc=net"])
  end

  it "updates shellentitlements for a user with only new ones" do
    user = ldap_entry("uid=mainecoon,ou=People,dc=kittens,dc=net")
    expect(user[:shellentitlements]).to eq([
      "cn=bar,ou=GroupOfNames,ou=Entitlements,ou=Groups,dc=kittens,dc=net",
      "cn=baz,ou=GroupOfNames,ou=Entitlements,ou=Groups,dc=kittens,dc=net"
    ])
  end

  it "leaves shellentitlements alone for a user with no changes" do
    user = ldap_entry("uid=blackmanx,ou=People,dc=kittens,dc=net")
    expect(user[:shellentitlements]).to eq(["cn=baz,ou=GroupOfNames,ou=Entitlements,ou=Groups,dc=kittens,dc=net"])
  end

  it "leaves shellentitlements alone for a user with no changes and no entitlements" do
    user = ldap_entry("uid=cheetoh,ou=People,dc=kittens,dc=net")
    expect(user[:cn]).to eq(["cheetoh"])
    expect(user[:shellentitlements]).to eq([])
  end

  it "creates and populates the lockout group (empty)" do
    dn_set = Set.new(%w[cn=locked-out,ou=pizza_teams,ou=groups,dc=kittens,dc=net])
    expect(members("cn=locked-out,ou=Pizza_Teams,ou=Groups,dc=kittens,dc=net")).to eq(dn_set)
  end

  it "updates GitHub organization membership for admins" do
    response = github_http_get("/entitlements-app-acceptance/orgs/admin")
    expect(response.code).to eq("200")
    users = Set.new(JSON.parse(response.body)["users"])
    expected = Set.new(%w[blackmanx peterbald mainecoon])
    expect(users).to eq(expected)
  end

  it "updates GitHub organization membership for members" do
    response = github_http_get("/entitlements-app-acceptance/orgs/member")
    expect(response.code).to eq("200")
    users = Set.new(JSON.parse(response.body)["users"])
    expected = Set.new(["ojosazules", "cyprus", "donskoy", "chausie", "ragamuffin", "minskin", "khaomanee", "cheetoh", "nebelung"])
    expect(users.sort).to eq(expected.sort)
  end

  it "empties an expired entitlement" do
    expect(ldap_exist?("cn=expire-later,ou=Entitlements,ou=Groups,dc=kittens,dc=net")).to eq(true)
    expect(members("cn=expire-later,ou=Entitlements,ou=Groups,dc=kittens,dc=net")).to eq(Set.new(%w[cn=expire-later,ou=entitlements,ou=groups,dc=kittens,dc=net]))
  end

  it "updates a GitHub team role" do
    result = github_http_get("/teams/4/members")
    expect(result.code).to eq("200")
    obj = JSON.parse(result.body)
    expect(obj.map { |item| item["login"] }.sort).to eq(%w[nebelung cheetoh ojosazules blackmanx ragamuffin mainecoon].sort)
  end

  it "updates a GitHub team role" do
    result = github_http_get("/teams/5/members")
    expect(result.code).to eq("200")
    obj = JSON.parse(result.body)
    expect(obj.map { |item| item["login"] }.sort).to eq(%w[blackmanx mainecoon].sort)
  end

  it "no-ops a GitHub team role" do
    result = github_http_get("/teams/6/members")
    expect(result.code).to eq("200")
    obj = JSON.parse(result.body)
    expect(obj.map { |item| item["login"] }.sort).to eq(%w[nebelung khaomanee chausie cheetoh cyprus ojosazules].sort)
  end
end
