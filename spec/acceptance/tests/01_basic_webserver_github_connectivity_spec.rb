# frozen_string_literal: true

# By the time we run this test we have already tested connectivity from the master script. However running
# this basic verification confirms that we can connect to the fake web server, before moving into more complicated tests.

require_relative "spec_helper"
require "json"
require "net/http"

describe Entitlements do
  let(:uri) {}
  let(:token) { "meowmeowmeowmeowmeow" }
  let(:result) do
    u = URI.parse(File.join("https://github.fake", uri))
    Net::HTTP.start(u.host, u.port, use_ssl: true) do |http|
      request = Net::HTTP::Get.new(u.request_uri)
      request["Authorization"] = "token #{token}"
      http.request(request)
    end
  end

  context "test endpoint" do
    let(:uri) { "/ping" }

    it "connects successfully" do
      expect(result.code.to_i).to eq(200)
      expect(result.body).to eq("OK")
    end
  end

  context "specific team endpoint" do
    let(:uri) { "/teams/5" }

    it "returns the expected team data" do
      expect(result.code.to_i).to eq(200)
      data = JSON.parse(result.body)
      expect(data["name"]).to eq("grumpy-cat")
      expect(data["members_count"]).to eq(4)
    end
  end

  context "graphql endpoint" do
    it "returns the expected data" do
      u = URI.parse("https://github.fake/graphql")
      query = "{
        organization(login: \"github\") {
          team(slug: \"colonel-meow\") {
            id
            members(first: 100) {
              edges {
                node {
                  login
                }
                role
                cursor
              }
            },
          parentTeam {
            slug
          }
        }
      }".gsub(/\n\s+/, "\n")

      result = Net::HTTP.start(u.host, u.port, use_ssl: true) do |http|
        request = Net::HTTP::Post.new(u.request_uri)
        request.add_field("Authorization", "bearer #{token}")
        request.add_field("Content-Type", "application/json")
        request.body = JSON.generate("query" => query)
        http.request(request)
      end

      expect(result.code.to_i).to eq(200)
      result_data = JSON.parse(result.body)
      expect(result_data).to eq(
        {
          "data" => {
            "organization" => {
              "team" => {
                "databaseId" => 6,
                "members" => {
                  "edges" => [
                    { "node" => { "login" => "cheetoh" }, "role" => "MEMBER", "cursor" => "Y2hlZXRvaA==" },
                    { "node" => { "login" => "khaomanee" }, "role" => "MEMBER", "cursor" => "a2hhb21hbmVl" },
                    { "node" => { "login" => "nebelung" }, "role" => "MEMBER", "cursor" => "bmViZWx1bmc=" },
                    { "node" => { "login" => "ojosazules" }, "role" => "MEMBER", "cursor" => "b2pvc2F6dWxlcw==" }
                  ]
                },
                "parentTeam" => { "slug" => nil },
              }
            }
          }
        }
      )
    end
  end
end
