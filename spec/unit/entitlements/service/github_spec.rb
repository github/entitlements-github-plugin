# frozen_string_literal: true
require_relative "../../spec_helper"
require "ostruct"

describe Entitlements::Service::GitHub do
  let(:subject) do
    described_class.new(
      addr: "https://github.fake/api/v3",
      org: "kittensinc",
      token: "GoPackGo",
      ou: "ou=kittensinc,ou=GitHub,dc=github,dc=fake",
      ignore_not_found: false
    )
  end

  describe "#identifier" do
    it "returns 'github.com' when address is not specified" do
      subject = described_class.new(
        org: "kittensinc",
        token: "GoPackGo",
        ou: "ou=kittensinc,ou=GitHub,dc=github,dc=fake",
        ignore_not_found: false
      )
      expect(subject.identifier).to eq("github.com")
    end

    it "returns the host part of the URL when address is specified" do
      expect(subject.identifier).to eq("github.fake")
    end
  end

  describe "#org_members" do
    let(:members_and_roles) do
      {
        "alice"   => "MEMBER",
        "bob"     => "ADMIN",
        "charles" => "MEMBER",
        "david"   => "MEMBER"
      }
    end

    it "queries GraphQL and converts Enum to Entitlements key" do
      expect(subject).to receive(:members_and_roles_from_rest).and_return(members_and_roles)
      expect(subject.org_members).to eq(
                                       "alice" => "member", "bob" => "admin", "charles" => "member", "david" => "member"
                                     )
    end
  end

  describe "#enterprise?" do
    it "returns false if an instance is not enterprise" do
      stub_request(:get, "https://github.fake/api/v3/meta").
        to_return({
                    body: JSON.dump({ verifiable_password_authentication: true }),
                    headers: {
                      content_type: "application/json; charset=utf-8"
                    }
                  })

      expect(subject.enterprise?).to eq(false)
    end

    it "returns true if an instance is enterprise" do
      stub_request(:get, "https://github.fake/api/v3/meta").
        to_return({
                    body: JSON.dump({ installed_version: "1.0" }),
                    headers: {
                      content_type: "application/json; charset=utf-8"
                    }
                  })
      expect(subject.enterprise?).to eq(true)
    end
  end

  describe "#pending_members" do
    let(:user_set) { Set.new(%w[bob tom blackmanx]) }

    it "logs a message and then returns the result from pending_members_from_graphql" do
      expect(subject).to receive(:enterprise?).and_return(false)
      expect(subject).to receive(:pending_members_from_graphql).and_return(user_set)
      expect(subject.pending_members).to eq(user_set)
    end
  end

  describe "#org_members_from_predictive_cache?" do
    let(:admin_dn) { "cn=admin,ou=kittensinc,ou=GitHub,dc=github,dc=fake" }
    let(:member_dn) { "cn=member,ou=kittensinc,ou=GitHub,dc=github,dc=fake" }
    let(:admins) { Set.new(%w[monalisa]) }
    let(:members) { Set.new(%w[ocicat blackmanx toyger]) }
    let(:answer) { { "monalisa" => "ADMIN", "ocicat" => "MEMBER", "blackmanx" => "MEMBER", "toyger" => "MEMBER" } }

    context "when not in the cache" do
      it "returns false" do
        cache[:predictive_state] = { by_dn: { admin_dn => { members: admins, metadata: nil } }, invalid: Set.new }

        expect(subject).to receive(:members_and_roles_from_rest).and_return(answer)

        expect(subject.org_members_from_predictive_cache?).to eq(false)
      end
    end

    context "when sourced from the cache" do
      it "returns true" do
        cache[:predictive_state] = { by_dn: { admin_dn => { members: admins, metadata: nil }, member_dn => { members:, metadata: nil } }, invalid: Set.new }

        expect(subject).not_to receive(:members_and_roles_from_rest)

        expect(subject.org_members_from_predictive_cache?).to eq(true)
      end
    end
  end

  describe "#invalidate_org_members_predictive_cache" do
    let(:admin_dn) { "cn=admin,ou=kittensinc,ou=GitHub,dc=github,dc=fake" }
    let(:member_dn) { "cn=member,ou=kittensinc,ou=GitHub,dc=github,dc=fake" }
    let(:admins) { Set.new(%w[monalisa]) }
    let(:members) { Set.new(%w[ocicat blackmanx toyger]) }
    let(:answer) { { "monalisa" => "ADMIN", "ocicat" => "MEMBER", "blackmanx" => "MEMBER", "toyger" => "MEMBER" } }

    it "invaliates the cache" do
      cache[:predictive_state] = { by_dn: { admin_dn => { members: admins, metadata: nil }, member_dn => { members:, metadata: nil } }, invalid: Set.new }

      # First load should read from the cache.
      expect(subject.org_members).to eq(answer.map { |k, v| [k, v.downcase] }.to_h)

      # Invalidating cache should force a re-read.
      answer_2 = answer.dup
      answer_2["ragamuffin"] = "ADMIN"

      expect(subject).to receive(:members_and_roles_from_rest).and_return(answer_2)
      expect(logger).to receive(:debug).with("Invalidating cache entries for cn=(admin|member),ou=kittensinc,ou=GitHub,dc=github,dc=fake")
      expect(logger).to receive(:debug).with("members(cn=admin,ou=kittensinc,ou=GitHub,dc=github,dc=fake): DN has been marked invalid in cache")
      expect(logger).to receive(:debug).with("members(cn=member,ou=kittensinc,ou=GitHub,dc=github,dc=fake): DN has been marked invalid in cache")
      expect(logger).to receive(:debug).with("Currently kittensinc has 2 admin(s) and 3 member(s)")
      subject.invalidate_org_members_predictive_cache

      # Check that the re-read has occurred and the correct result is achieved.
      expect(subject).not_to receive(:members_and_roles_from_graphql) # Should already be in object's cache
      expect(subject.org_members).to eq(answer_2.map { |k, v| [k, v.downcase] }.to_h)
    end
  end

  describe "#members_and_roles_from_graphql_or_cache" do
    let(:admin_dn) { "cn=admin,ou=kittensinc,ou=GitHub,dc=github,dc=fake" }
    let(:member_dn) { "cn=member,ou=kittensinc,ou=GitHub,dc=github,dc=fake" }
    let(:admins) { Set.new(%w[monalisa]) }
    let(:members) { Set.new(%w[ocicat blackmanx toyger]) }
    let(:answer) { { "monalisa" => "ADMIN", "ocicat" => "MEMBER", "blackmanx" => "MEMBER", "toyger" => "MEMBER" } }

    context "with data available from cache" do
      it "logs and returns data from cache" do
        cache[:predictive_state] = { by_dn: { admin_dn => { members: Set.new(admins), metadata: nil }, member_dn => { members: Set.new(members), metadata: nil } }, invalid: Set.new }

        expect(subject).not_to receive(:members_and_roles_from_rest)
        expect(logger).to receive(:debug).with("Loading organization members and roles for kittensinc from cache")

        result = subject.send(:members_and_roles_from_graphql_or_cache)
        expect(result).to eq([answer, true])
      end
    end

    context "with data in cache invalid" do
      it "calls members_and_roles_from_graphql" do
        cache[:predictive_state] = { by_dn: {}, invalid: Set.new }

        expect(logger).to receive(:debug).with("members(#{admin_dn}): DN does not exist in cache")
        expect(logger).to receive(:debug).with("members(#{member_dn}): DN does not exist in cache")
        expect(subject).to receive(:members_and_roles_from_rest).and_return(answer)

        result = subject.send(:members_and_roles_from_graphql_or_cache)
        expect(result).to eq([answer, false])
      end
    end
  end

  describe "#members_and_roles_from_graphql" do
    context "happy path" do
      it "returns the expected hash" do
        allow(subject).to receive(:max_graphql_results).and_return(3)

        stub_request(:post, "https://github.fake/api/v3/graphql").
          with(body: /\(first: 3\)/).
          to_return(status: 200, body: File.read(fixture("graphql-output/organization-members-page1.json")))

        stub_request(:post, "https://github.fake/api/v3/graphql").
          with(body: /\(first: 3, after: \\"Y3Vyc29yOnYyOpEG\\"\)/).
          to_return(status: 200, body: File.read(fixture("graphql-output/organization-members-page2.json")))

        stub_request(:post, "https://github.fake/api/v3/graphql").
          with(body: /\(first: 3, after: \\"Y3Vyc29yOnYyOpEJ\\"\)/).
          to_return(status: 200, body: File.read(fixture("graphql-output/organization-members-page3.json")))

        stub_request(:post, "https://github.fake/api/v3/graphql").
          with(body: /\(first: 3, after: \\"Y3Vyc29yOnYyOpEM\\"\)/).
          to_return(status: 200, body: File.read(fixture("graphql-output/organization-members-page4.json")))

        result = subject.send(:members_and_roles_from_graphql)
        expect(result).to eq({"ocicat"=>"MEMBER", "blackmanx"=>"MEMBER", "toyger"=>"MEMBER", "highlander"=>"MEMBER", "russianblue"=>"MEMBER", "ragamuffin"=>"MEMBER", "monalisa"=>"ADMIN", "peterbald"=>"MEMBER", "mainecoon"=>"MEMBER", "laperm"=>"MEMBER"})
      end
    end

    context "sad path" do
      it "raises" do
        stub_request(:post, "https://github.fake/api/v3/graphql").to_return(status: 404)
        expect(logger).to receive(:fatal).with(/Abort due to GraphQL failure on /)
        expect { subject.send(:members_and_roles_from_graphql) }.to raise_error(/GraphQL query failure/)
      end
    end
  end

  describe "#members_and_roles_from_rest" do
    context "happy path" do
      let(:members) { %w[ocicat blackmanx toyger highlander russianblue ragamuffin peterbald mainecoon laperm] }
      let(:admins) { %w[monalisa] }
      let(:octokit) { instance_double(Octokit::Client) }

      it "returns the expected hash" do
        expect(subject).to receive(:octokit).and_return(octokit).twice
        expect(octokit).to receive(:organization_members).with("kittensinc", { role: "admin" }).and_return(admins.map { |login| { login: } })
        expect(octokit).to receive(:organization_members).with("kittensinc", { role: "member" }).and_return(members.map { |login| { login: } })

        result = subject.send(:members_and_roles_from_rest)
        expect(result).to eq({"ocicat"=>"MEMBER", "blackmanx"=>"MEMBER", "toyger"=>"MEMBER", "highlander"=>"MEMBER", "russianblue"=>"MEMBER", "ragamuffin"=>"MEMBER", "monalisa"=>"ADMIN", "peterbald"=>"MEMBER", "mainecoon"=>"MEMBER", "laperm"=>"MEMBER"})
      end
    end
  end

  describe "#pending_members_from_graphql" do
    context "happy path" do
      it "returns the expected hash" do
        allow(subject).to receive(:max_graphql_results).and_return(3)

        stub_request(:post, "https://github.fake/api/v3/graphql").
          with(body: /\(first: 3\)/).
          to_return(status: 200, body: File.read(fixture("graphql-output/pending-members-page1.json")))

        stub_request(:post, "https://github.fake/api/v3/graphql").
          with(body: /\(first: 3, after: \\"Y3Vyc29yOnYyOpEG\\"\)/).
          to_return(status: 200, body: File.read(fixture("graphql-output/pending-members-page2.json")))

        stub_request(:post, "https://github.fake/api/v3/graphql").
          with(body: /\(first: 3, after: \\"Y3Vyc29yOnYyOpEJ\\"\)/).
          to_return(status: 200, body: File.read(fixture("graphql-output/pending-members-page3.json")))

        stub_request(:post, "https://github.fake/api/v3/graphql").
          with(body: /\(first: 3, after: \\"Y3Vyc29yOnYyOpEM\\"\)/).
          to_return(status: 200, body: File.read(fixture("graphql-output/pending-members-page4.json")))

        result = subject.send(:pending_members_from_graphql)
        expect(result).to eq(Set.new(%w[alice bob charles david edward frank george harriet ingrid blackmanx]))
      end
    end

    context "sad path" do
      it "raises" do
        stub_request(:post, "https://github.fake/api/v3/graphql").to_return(status: 404)
        expect(logger).to receive(:fatal).with(/Abort due to GraphQL failure on /)
        expect { subject.send(:pending_members_from_graphql) }.to raise_error(/GraphQL query failure/)
      end
    end
  end

  describe "#graphql_http_post" do
    let(:answer) { { "foo" => "bar" } }
    let(:query) { "my query here" }

    it "returns immediately for success" do
      expect(subject).to receive(:graphql_http_post_real).with(query).and_return(code: 200, data: answer)
      expect_any_instance_of(Object).not_to receive(:sleep)
      expect(logger).not_to receive(:warn)
      expect(logger).not_to receive(:error)

      response = subject.send(:graphql_http_post, query)
      expect(response[:code]).to eq(200)
      expect(response[:data]).to eq(answer)
    end

    it "returns immediately for 404" do
      expect(subject).to receive(:graphql_http_post_real).with(query).and_return(code: 404, data: answer)
      expect_any_instance_of(Object).not_to receive(:sleep)
      expect(logger).not_to receive(:warn)
      expect(logger).not_to receive(:error)

      response = subject.send(:graphql_http_post, query)
      expect(response[:code]).to eq(404)
      expect(response[:data]).to eq(answer)
    end

    it "retries for 500" do
      expect(subject).to receive(:graphql_http_post_real).with(query).and_return({ code: 500, data: answer }, { code: 200, data: answer })
      expect_any_instance_of(Object).to receive(:sleep).with(1).exactly(1).times
      expect(logger).to receive(:warn).with("GraphQL failed on try 1 of 3. Will retry.")
      expect(logger).not_to receive(:error)

      response = subject.send(:graphql_http_post, query)
      expect(response[:code]).to eq(200)
      expect(response[:data]).to eq(answer)
    end

    it "gives up and returns the last failure when tries are exceeded" do
      fail_hash = { code: 502, data: answer }
      expect(subject).to receive(:graphql_http_post_real).with(query).and_return(fail_hash, fail_hash, fail_hash)
      expect_any_instance_of(Object).to receive(:sleep).with(1).exactly(1).times
      expect_any_instance_of(Object).to receive(:sleep).with(2).exactly(1).times
      expect(logger).to receive(:warn).with("GraphQL failed on try 1 of 3. Will retry.")
      expect(logger).to receive(:warn).with("GraphQL failed on try 2 of 3. Will retry.")
      expect(logger).to receive(:error).with("Query still failing after 3 tries. Giving up.")

      response = subject.send(:graphql_http_post, query)
      expect(response[:code]).to eq(502)
      expect(response[:data]).to eq(answer)
    end
  end

  describe "#graphql_http_post_real" do
    it "returns code=200 and parsed JSON for a successful response" do
      answer = { "foo" => ["bar", "baz" => "fizz"] }
      stub_request(:post, "https://github.fake/api/v3/graphql").to_return(status: 200, body: JSON.generate(answer))
      response = subject.send(:graphql_http_post_real, "nonsense")
      expect(response).to eq(code: 200, data: answer)
    end

    it "logs and returns code=500 and exception message for an unhandled exception" do
      exc = StandardError.new("Oh no you don't")
      stub_request(:post, "https://github.fake/api/v3/graphql").to_raise(exc)
      expect(logger).to receive(:error).with("Caught StandardError POSTing to https://github.fake/api/v3/graphql: Oh no you don't")
      response = subject.send(:graphql_http_post_real, "nonsense")
      expect(response).to eq(code: 500, data: nil)
    end

    it "logs and returns code and body for non-200 response" do
      answer = { "errors" => ["message" => "Something busted"] }
      stub_request(:post, "https://github.fake/api/v3/graphql").to_return(status: 429, body: JSON.generate(answer))
      expect(logger).to receive(:error).with("Got HTTP 429 POSTing to https://github.fake/api/v3/graphql")
      expect(logger).to receive(:error).with("{\"errors\":[{\"message\":\"Something busted\"}]}")
      response = subject.send(:graphql_http_post_real, "nonsense")
      expect(response).to eq(code: 429, data: { "body" => JSON.generate(answer) })
    end

    it "logs and returns raw text for JSON parsing error" do
      answer = "mor chicken mor rewardz!"
      stub_request(:post, "https://github.fake/api/v3/graphql").to_return(status: 200, body: answer)
      expect(logger).to receive(:error).with("JSON::ParserError unexpected token at 'mor chicken mor rewardz!': \"mor chicken mor rewardz!\"")
      response = subject.send(:graphql_http_post_real, "nonsense")
      expect(response).to eq(code: 500, data: { "body" => "mor chicken mor rewardz!" })
    end

    it "logs and returns when errors are reported in a 200" do
      answer = { "errors" => ["ENOTENOUGHCHICKEn"] }
      stub_request(:post, "https://github.fake/api/v3/graphql").to_return(status: 200, body: JSON.generate(answer))
      expect(logger).to receive(:error).with("Errors reported: [\"ENOTENOUGHCHICKEn\"]")
      response = subject.send(:graphql_http_post_real, "nonsense")
      expect(response).to eq(code: 500, data: answer)
    end
  end
end
