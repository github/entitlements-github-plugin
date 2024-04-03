# frozen_string_literal: true

require "simplecov"
require "simplecov-erb"

COV_DIR = File.expand_path("../../coverage", File.dirname(__FILE__))

SimpleCov.root File.expand_path("../../", File.dirname(__FILE__))
SimpleCov.coverage_dir COV_DIR

SimpleCov.formatters = [
  SimpleCov::Formatter::HTMLFormatter,
  SimpleCov::Formatter::ERBFormatter
]

SimpleCov.minimum_coverage 100

SimpleCov.at_exit do
  File.write("#{COV_DIR}/total-coverage.txt", SimpleCov.result.covered_percent)
  SimpleCov.result.format!
end

SimpleCov.start do
  # don't show specs as missing coverage for themselves
  add_filter "/spec/"

  # don't analyze coverage for gems
  add_filter "/vendor/gems/"
end

require "base64"
require "contracts"
require "json"
require "rspec"
require "rspec/support"
require "rspec/support/object_formatter"
require "tempfile"
require "vcr"
require "webmock/rspec"

require "entitlements"

require_relative "../../lib/entitlements/backend/github_org"
require_relative "../../lib/entitlements/backend/github_team"
require_relative "../../lib/entitlements/service/github"

def fixture(path)
  File.expand_path(File.join("fixtures", path.sub(%r{\A/+}, "")), File.dirname(__FILE__))
end

def default_filters
  {
    "contractors" => :none,
    "lockout"     => :none,
    "pre-hires"   => :none,
  }
end

def graphql_response(team, slice_start, slice_length, parent_team: nil)
  team_id = rand(1..10000)
  edges = team.member_strings.sort.to_a.slice(slice_start, slice_length).map do |m|
    { "node" => { "login" => m }, "role" => "MEMBER", "cursor" => Base64.encode64(m) }
  end
  struct = {
    "data" => {
      "organization" => {
        "team" => {
          "databaseId" => team_id,
          "members" => {
            "edges" => edges
          },
          "parentTeam" => {
            "slug" => parent_team
          }
        }
      }
    }
  }
  JSON.generate(struct)
end

RSpec::Support::ObjectFormatter.default_instance.max_formatted_output_length = 100000

VCR.configure do |config|
  config.cassette_library_dir = "spec/fixtures/vcr_cassettes"
  config.default_cassette_options = { record: :once }
  config.hook_into :webmock
end
# These classes need to be stubbed since they come in via `load_extra` and need to be defined at
# compile time for some tests. But we are not necessarily loading every extra for every test.
module Entitlements
  module Extras
    class Base; end
    class LDAPGroup
      class Base < Entitlements::Extras::Base; end
      class Filters
        class MemberOfLDAPGroup < Entitlements::Data::Groups::Calculated::Filters::Base; end
      end
      class Rules
        class LDAPGroup < Entitlements::Data::Groups::Calculated::Rules::Base; end
      end
    end
    class Orgchart
      class Base < Entitlements::Extras::Base; end
      class Logic; end
      class PersonMethods < Entitlements::Extras::Orgchart::Base; end
      class Rules
        class DirectReport < Entitlements::Data::Groups::Calculated::Rules::Base; end
        class Management < Entitlements::Data::Groups::Calculated::Rules::Base; end
      end
    end
  end
end

def setup_default_filters
  contractor_cfg = {
    class: Entitlements::Data::Groups::Calculated::Filters::MemberOfGroup,
    config: { "group" => "internal/contractors" }
  }
  lockout_cfg = {
    class: Entitlements::Extras::LDAPGroup::Filters::MemberOfLDAPGroup,
    config: { "ldap_group" => "cn=lockout,ou=Groups,dc=kittens,dc=net" }
  }
  pre_hire_cfg = {
    class: Entitlements::Data::Groups::Calculated::Filters::MemberOfGroup,
    config: { "group" => "internal/pre-hires" }
  }
  Entitlements::Data::Groups::Calculated.register_filter("contractors", contractor_cfg)
  Entitlements::Data::Groups::Calculated.register_filter("lockout", lockout_cfg)
  Entitlements::Data::Groups::Calculated.register_filter("pre-hires", pre_hire_cfg)
end

# Singleton classes that need to have state cleared out of them before each test, to avoid
# results from different tests leaking between them.

def reset_singleton_classes
  Entitlements.instance_variable_set("@cache", nil)
  Entitlements.instance_variable_set("@child_classes", nil)
  Entitlements.instance_variable_set("@config", nil)
  Entitlements.instance_variable_set("@config_file", nil)
  Entitlements.instance_variable_set("@config_path_override", nil)
  Entitlements.instance_variable_set("@person_extra_methods", {})

  extras_loaded = Entitlements.instance_variable_get("@extras_loaded")
  if extras_loaded
    extras_loaded.each { |clazz| clazz.reset! if clazz.respond_to?(:reset!) }
  end
  Entitlements.instance_variable_set("@extras_loaded", nil)

  Entitlements::Data::Groups::Calculated.instance_variable_set("@rules_index", {
    "group"    => Entitlements::Data::Groups::Calculated::Rules::Group,
    "username" => Entitlements::Data::Groups::Calculated::Rules::Username
  })
  Entitlements::Data::Groups::Calculated.instance_variable_set("@filters_index", {})
  Entitlements::Data::Groups::Calculated.instance_variable_set("@groups_in_ou_cache", {})
  Entitlements::Data::Groups::Calculated.instance_variable_set("@groups_cache", {})
  Entitlements::Data::Groups::Calculated.instance_variable_set("@config_cache", {})
end

module MyLetDeclarations
  extend RSpec::SharedContext
  let(:cache) { {} }
  let(:entitlements_config_file) { fixture("config.yaml") }
  let(:entitlements_config_hash) { nil }
  let(:logger) { Entitlements.dummy_logger }
end

module Contracts
  module RSpec
    module Mocks
      def instance_double(klass, *args)
        super.tap do |double|
          allow(double).to receive(:is_a?).with(klass).and_return(true)
          allow(double).to receive(:is_a?).with(ParamContractError).and_return(false)
        end
      end
    end
  end
end

RSpec.configure do |config|
  config.include Contracts::RSpec::Mocks
  config.include MyLetDeclarations

  config.before :each do
    allow(Time).to receive(:now).and_return(Time.utc(2018, 4, 1, 12, 0, 0))
    allow(Entitlements).to receive(:cache).and_return(cache)
    if entitlements_config_hash
      Entitlements.config = entitlements_config_hash
    else
      Entitlements.config_file = entitlements_config_file
      Entitlements.validate_configuration_file!
    end
    Entitlements.set_logger(logger)
  end

  config.after :each do
    reset_singleton_classes
  end
end
