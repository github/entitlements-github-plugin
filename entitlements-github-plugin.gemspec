# frozen_string_literal: true

require_relative "lib/version"

Gem::Specification.new do |s|
  s.name = "entitlements-github-plugin"
  s.version = Entitlements::Version::VERSION
  s.summary = "GitHub dotcom provider for entitlements-app"
  s.description = "Entitlements plugin to manage GitHub Orgs and Team memberships and access"
  s.authors = ["GitHub, Inc. Security Ops"]
  s.email = "security@github.com"
  s.license = "MIT"
  s.files = Dir.glob("lib/**/*")
  s.homepage = "https://github.com/github/entitlements-github-plugin"
  s.executables = %w[]

  s.required_ruby_version = ">= 3.0.0"

  s.add_dependency "contracts", "~> 0.17.0"
  s.add_dependency "faraday", "~> 2.0"
  s.add_dependency "faraday-retry", "~> 2.0"
  s.add_dependency "octokit", "~> 4.25"

  s.add_development_dependency "entitlements-app", "~> 1.0"
  s.add_development_dependency "rake", "~> 13.2", ">= 13.2.1"
  s.add_development_dependency "rspec", "= 3.13.0"
  s.add_development_dependency "rubocop", "~> 1.64"
  s.add_development_dependency "rubocop-github", "~> 0.20"
  s.add_development_dependency "rubocop-performance", "~> 1.21"
  s.add_development_dependency "ruby-lsp", "~> 0.17.4"
  s.add_development_dependency "rugged", "~> 1.7", ">= 1.7.2"
  s.add_development_dependency "simplecov", "~> 0.22.0"
  s.add_development_dependency "simplecov-erb", "~> 1.0", ">= 1.0.1"
  s.add_development_dependency "vcr", "~> 6.2"
  s.add_development_dependency "webmock", "~> 3.23", ">= 3.23.1"
end
