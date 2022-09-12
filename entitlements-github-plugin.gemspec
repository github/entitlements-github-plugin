# frozen_string_literal: true

Gem::Specification.new do |s|
  s.name = "entitlements-github-plugin"
  s.version = File.read("VERSION").chomp
  s.summary = "GitHub dotcom provider for entitlements-app"
  s.description = ""
  s.authors = ["GitHub, Inc. Security Ops"]
  s.email = "security@github.com"
  s.license = "MIT"
  s.files = Dir.glob("lib/**/*") + %w[VERSION]
  s.homepage = "https://github.com/github/entitlements-github-plugin"
  s.executables = %w[]

  s.add_dependency "contracts", "= 0.17.0"
  s.add_dependency "faraday", "~> 2.0"
  s.add_dependency "faraday-retry", "~> 2.0"
  s.add_dependency "octokit", "~> 4.25"

  s.add_development_dependency "entitlements", "0.2.0"
  s.add_development_dependency "rake", "= 13.0.6"
  s.add_development_dependency "rspec", "= 3.8.0"
  s.add_development_dependency "rspec-core", "= 3.8.0"
  s.add_development_dependency "rubocop", "= 1.29.1"
  s.add_development_dependency "rubocop-github", "= 0.17.0"
  s.add_development_dependency "rubocop-performance", "= 1.13.3"
  s.add_development_dependency "rugged", "= 0.27.5"
  s.add_development_dependency "simplecov", "= 0.16.1"
  s.add_development_dependency "simplecov-erb", "= 1.0.1"
  s.add_development_dependency "vcr", "= 4.0.0"
  s.add_development_dependency "webmock", "3.4.2"
end
