# frozen_string_literal: true

require "base64"
require "fileutils"
require "json"
require "sinatra/base"
require "webrick"
require "webrick/https"
require "openssl"

class FakeGitHubApi < Sinatra::Base
  set :server, %w[webrick]
  set :server_settings, {
    Host: "0.0.0.0",
    Port: 443,
    Logger: WEBrick::Log::new($stderr, WEBrick::Log::DEBUG),
    SSLEnable: true,
    SSLVerifyClient: OpenSSL::SSL::VERIFY_NONE,
    SSLCertificate: OpenSSL::X509::Certificate.new(File.read("/acceptance/github-server/ssl.crt")),
    SSLPrivateKey: OpenSSL::PKey::RSA.new(File.read("/acceptance/github-server/ssl.key")),
    SSLCertName: [["CN", "github.fake"]]
  }

  set :port, 443
  set :bind, "0.0.0.0"

  BASE_DIR = "/tmp/github"

  TEAM_MAP_FILE = File.join(BASE_DIR, "team_map.json")

  def self.user(user_id)
    uid = user_id.hash % 65536
    {
      "login"               => user_id,
      "id"                  => uid,
      "node_id"             => "MDQ6VXNlcjM=",
      "avatar_url"          => "http://alambic.github.localhost/avatars/u/#{uid}?",
      "gravatar_id"         => "",
      "url"                 => "http://api.github.localhost/users/#{user_id}",
      "html_url"            => "http://github.localhost/#{user_id}",
      "followers_url"       => "http://api.github.localhost/users/#{user_id}/followers",
      "following_url"       => "http://api.github.localhost/users/#{user_id}/following{/other_user}",
      "gists_url"           => "http://api.github.localhost/users/#{user_id}/gists{/gist_id}",
      "starred_url"         => "http://api.github.localhost/users/#{user_id}/starred{/owner}{/repo}",
      "subscriptions_url"   => "http://api.github.localhost/users/#{user_id}/subscriptions",
      "organizations_url"   => "http://api.github.localhost/users/#{user_id}/orgs",
      "repos_url"           => "http://api.github.localhost/users/#{user_id}/repos",
      "events_url"          => "http://api.github.localhost/users/#{user_id}/events{/privacy}",
      "received_events_url" => "http://api.github.localhost/users/#{user_id}/received_events",
      "type"                => "User",
      :"site_admin" => true
    }
  end

  before do
    unless env["HTTP_AUTHORIZATION"] =~ /(bearer|token) meowmeowmeowmeowmeow/
      halt 403
    end
    content_type "application/json"
  end

  def graphql_team_query(query)
    team_map = JSON.parse(File.read(TEAM_MAP_FILE))
    cursor = nil
    first = 100
    slug = Regexp.last_match(1) if query =~ /team\(slug: "(.+?)"/
    first = Regexp.last_match(1).to_i if query =~ /members\(first: (\d+)/
    cursor = Regexp.last_match(1) if query =~ /members\(first: \d+, after: "(.+?)"/

    if team_map.key?(slug)
      team_id = team_map[slug]["id"]
      parent_team_name = team_map[slug][:parent_team_name]

      member_dir = File.join(BASE_DIR, "members", team_map[slug]["id"].to_s)
      members = Dir.glob(File.join(member_dir, "*")).sort.map { |filename| File.basename(filename) }
      edges = []
      cursor_flag = cursor.nil?
      members.each do |m|
        next if !cursor_flag && Base64.strict_encode64(m) != cursor
        edges << { "node" => { "login" => m }, "role" => "MEMBER", "cursor" => Base64.strict_encode64(m) } if cursor_flag
        cursor_flag = true
        break if edges.size >= first
      end

      {
        "organization" => {
          "team" => {
            "databaseId" => team_id,
            "members" => {
              "edges" => edges
            },
            "parentTeam" => {
              "slug" => parent_team_name
            }
          }
        }
      }
    else
      { "organization" => { "team" => nil } }
    end
  end

  def graphql_org_query(query)
    cursor = nil
    first = 100
    first = Regexp.last_match(1).to_i if query =~ /membersWithRole\(first: (\d+)/
    cursor = Regexp.last_match(1) if query =~ /membersWithRole\(first: \d+, after: "(.+?)"/
    role_map = { "admin" => "ADMIN", "member" => "MEMBER" }

    result = {}
    org_dir = File.join(BASE_DIR, "org")
    Dir.glob(File.join(org_dir, "*", "*")).each do |filename|
      user = File.basename(filename)
      role = File.basename(File.dirname(filename))
      result[user] = role_map.fetch(role)
    end

    edges = []
    cursor_flag = cursor.nil?
    end_cursor = nil
    result.each do |user, role|
      end_cursor = Base64.strict_encode64(user)
      next if !cursor_flag && end_cursor != cursor
      edges << { "node" => { "login" => user }, "role" => role} if cursor_flag
      cursor_flag = true
      break if edges.size >= first
    end

    {
      "organization" => {
        "membersWithRole" => {
          "edges" => edges,
          "pageInfo" => {
              "endCursor" => end_cursor
          }
        }
      }
    }
  end

  def graphql_pending_query(query)
    cursor = nil
    first = 100
    first = Regexp.last_match(1).to_i if query =~ /pendingMembers\(first: (\d+)/
    cursor = Regexp.last_match(1) if query =~ /pendingMembers\(first: \d+, after: "(.+?)"/

    result = Set.new
    pending_dir = File.join(BASE_DIR, "pending")
    Dir.glob(File.join(pending_dir, "*")).each do |filename|
      user = File.basename(filename)
      result.add(user)
    end

    edges = []
    cursor_flag = cursor.nil?
    end_cursor = nil
    result.each do |user|
      end_cursor = Base64.strict_encode64(user)
      next if !cursor_flag && end_cursor != cursor
      edges << { "node" => { "login" => user } } if cursor_flag
      cursor_flag = true
      break if edges.size >= first
    end

    {
      "organization" => {
        "pendingMembers" => {
          "edges" => edges,
          "pageInfo" => {
              "endCursor" => end_cursor
          }
        }
      }
    }
  end

  send :get, "/ping" do
    "OK"
  end

  send :get, "/meta" do
    JSON.generate({
          body: JSON.dump({ verifiable_password_authentication: true }),
          headers: {
            content_type: "application/json; charset=utf-8"
          }
        })
  end

  send :get, "/orgs/:org_name/teams" do
    halt 400
  end

  send :get, "/entitlements-app-acceptance/orgs/:role" do
    org_dir = File.join(BASE_DIR, "org", params["role"])
    users = Dir.glob(File.join(org_dir, "*")).map { |filename| File.basename(filename) }
    JSON.generate("users" => users)
  end

  send :get, "/entitlements-app-acceptance/pending" do
    pending_dir = File.join(BASE_DIR, "pending")
    users = Dir.glob(File.join(pending_dir, "*")).map { |filename| File.basename(filename) }
    JSON.generate("users" => users)
  end

  send :delete, "/entitlements-app-acceptance/reset-teams" do
    member_dir = File.join(BASE_DIR, "members")
    FileUtils.rm_rf member_dir
    FileUtils.mkdir_p member_dir
    %w[4 5 6 7].each { |dirname| FileUtils.mkdir_p(File.join(member_dir, dirname)) }
    %w[nebelung khaomanee cheetoh ojosazules blackmanx russianblue ragamuffin mainecoon].each do |user|
      File.open(File.join(member_dir, "4", user), "w") { |f| f.puts Time.now.to_s }
    end
    %w[blackmanx russianblue ragamuffin mainecoon].each do |user|
      File.open(File.join(member_dir, "5", user), "w") { |f| f.puts Time.now.to_s }
    end
    %w[nebelung khaomanee cheetoh ojosazules].each do |user|
      File.open(File.join(member_dir, "6", user), "w") { |f| f.puts Time.now.to_s }
    end
    %w[blackmanx donskoy].each do |user|
      File.open(File.join(member_dir, "7", user), "w") { |f| f.puts Time.now.to_s }
    end
    halt 204
  end

  send :put, "/entitlements-app-acceptance/orgs/:role" do
    org_dir = File.join(BASE_DIR, "org", params["role"])
    request.body.rewind
    postdata = JSON.parse(request.body.read)
    Dir.glob(File.join(org_dir, "*")).each { |filename| FileUtils.rm_f(filename) }
    postdata["users"].each { |user| File.open(File.join(org_dir, user), "w") { |f| f.puts Time.now.to_s } }
    halt 204
  end

  send :put, "/entitlements-app-acceptance/pending" do
    pending_dir = File.join(BASE_DIR, "pending")
    request.body.rewind
    postdata = JSON.parse(request.body.read)
    Dir.glob(File.join(pending_dir, "*")).each { |filename| FileUtils.rm_f(filename) }
    postdata["users"].each { |user| File.open(File.join(pending_dir, user), "w") { |f| f.puts Time.now.to_s } }
    halt 204
  end

  send :get, "/teams/:team_id" do
    teamfile = File.join(BASE_DIR, "teams", "#{params['team_id']}.json")
    halt 404 unless File.file?(teamfile)
    member_dir = File.join(BASE_DIR, "members", params["team_id"])
    halt 404 unless File.directory?(member_dir)
    response = JSON.parse(File.read(teamfile))
    response["members_count"] = Dir.glob(File.join(member_dir, "*")).size
    JSON.generate(response)
  end

  send :get, "/teams/:team_id/members" do
    member_dir = File.join(BASE_DIR, "members", params["team_id"])
    halt 404 unless File.directory?(member_dir)
    members = Dir.glob(File.join(member_dir, "*")).sort.map { |filename| FakeGitHubApi.user(File.basename(filename)) }
    JSON.generate(members)
  end

  send :post, "/graphql" do
    request.body.rewind
    postdata = JSON.parse(request.body.read)
    query = postdata["query"]

    result = if query =~ /team\(slug:/
               graphql_team_query(query)
    elsif query =~ /membersWithRole\(/
      graphql_org_query(query)
    elsif query =~ /pendingMembers\(/
      graphql_pending_query(query)
    else
      halt 400
    end

    JSON.generate("data" => result)
  end

  send :put, "/teams/:team_id/memberships/:username" do
    member_dir = File.join(BASE_DIR, "members", params["team_id"])
    halt 400 unless File.directory?(member_dir)
    # Check for case sensitivity concerns
    halt 400 unless params["username"] == params["username"].downcase
    File.open(File.join(member_dir, params["username"]), "w") { |f| f.puts Time.now.to_s }
    JSON.generate("url" => request.url, "role" => "member", "state" => "active")
  end

  send :delete, "/teams/:team_id/memberships/:username" do
    member_dir = File.join(BASE_DIR, "members", params["team_id"])
    halt 400 unless File.directory?(member_dir)
    # Check for case sensitivity concerns
    halt 400 unless params["username"] == params["username"].downcase
    FileUtils.rm_f File.join(member_dir, params["username"])
    halt 204
  end

  send :put, "/orgs/:org_name/memberships/:username" do
    # Check for case sensitivity concerns
    halt 400 unless params["username"] == params["username"].downcase

    # Pull out the role from the request body, halt if not provided.
    request.body.rewind
    postdata = JSON.parse(request.body.read)
    halt 400 unless %[admin member].include?(postdata["role"])

    # Store the data.
    org_dir = File.join(BASE_DIR, "org")
    File.open(File.join(org_dir, postdata["role"], params["username"]), "w") { |f| f.puts Time.now.to_s }

    # Remove from any other roles they may be in.
    other_roles = %w[admin member] - [postdata["role"]]
    other_roles.each { |other_role| FileUtils.rm_f(File.join(org_dir, other_role, params["username"])) }

    # Act like the API.
    JSON.generate("url" => request.url, "role" => postdata["role"], "state" => "active")
  end

  send :delete, "/orgs/:org_name/memberships/:username" do
    # Check for case sensitivity concerns
    halt 400 unless params["username"] == params["username"].downcase

    # Remove from the role
    %w[admin member].each do |role|
      filename = File.join(BASE_DIR, "org", role, params["username"])
      FileUtils.rm_f(filename)
    end

    # Remove if pending
    filename = File.join(BASE_DIR, "pending", params["username"])
    FileUtils.rm_f(filename)

    # Remove the user from all the teams they might be a part of.
    Dir.glob(File.join(BASE_DIR, "members", "*", params["username"])).each { |file| FileUtils.rm_f(file) }

    # Act like the API
    halt 204
  end

  send :get, "/orgs/:org_name/members" do
    result = []
    org_dir = File.join(BASE_DIR, "org")
    Dir.glob(File.join(org_dir, "*", "*")).each do |filename|
      user = File.basename(filename)
      role = File.basename(File.dirname(filename))
      if role == params["role"]
        result << { login: user }
      end
    end
    JSON.generate(result)
  end

  send :post, "/orgs/:org_name/teams" do
    teamfile = File.join(BASE_DIR, "teams", "8.json")
    teamdata = {
      "name": "new-team",
      "id": 8,
      "node_id": "MDQ6VGVhbTI2",
      "slug": "new-team",
      "description": "New Team",
      "privacy": "closed",
      "url": "http://api.github.localhost/teams/8",
      "members_url": "http://api.github.localhost/teams/8/members{/member}",
      "repositories_url": "http://api.github.localhost/teams/8/repos",
      "permission": "pull",
      "parent_team_name": "employees",
      "parent_team_id": 4
    }

    # Write the new team file to disk (in the container)
    File.open(teamfile, "w") do |f|
      f.write(JSON.pretty_generate(teamdata))
    end

    # Write to the members folder
    member_dir = File.join(BASE_DIR, "members", "8")
    Dir.mkdir member_dir

    # Write to the team map
    tmp_map = JSON.parse(File.read(TEAM_MAP_FILE))
    tmp_map["new-team"] = { id: 8, parent_team_name: "grumpy-cat", parent_team_id: 5 }
    File.open(TEAM_MAP_FILE, "w") do |f|
      f.write(JSON.pretty_generate(tmp_map))
    end

    [201, { "Content-Type" => "application/json" }, [JSON.generate(teamdata)]]
  end

  send :get, "/orgs/:org_name/teams/:team_name" do
    team_map = JSON.parse(File.read(TEAM_MAP_FILE))
    teamfile = File.join(BASE_DIR, "teams", "#{team_map[params['team_name']]["id"]}.json")
    halt 404 unless File.file?(teamfile)
    member_dir = File.join(BASE_DIR, "members", "#{team_map[params['team_name']]["id"]}")
    halt 404 unless File.directory?(member_dir)
    response = JSON.parse(File.read(teamfile))
    response["members_count"] = Dir.glob(File.join(member_dir, "*")).size
    JSON.generate(response)
  end

  send :patch, "/teams/:team_id" do
    teamfile = File.join(BASE_DIR, "teams", "#{params['team_id']}.json")
    halt 404 unless File.file?(teamfile)
    halt 201
  end

  [:get, :patch, :put, :delete, :post].each do |verb|
    send verb, "/*" do
      raise "No route registered for #{params}. Take a look in #{__FILE__}"
    end
  end
end

FakeGitHubApi.run!
