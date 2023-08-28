# entitlements-github-plugin

[![acceptance](https://github.com/github/entitlements-github-plugin/actions/workflows/acceptance.yml/badge.svg)](https://github.com/github/entitlements-github-plugin/actions/workflows/acceptance.yml) [![test](https://github.com/github/entitlements-github-plugin/actions/workflows/test.yml/badge.svg)](https://github.com/github/entitlements-github-plugin/actions/workflows/test.yml) [![lint](https://github.com/github/entitlements-github-plugin/actions/workflows/lint.yml/badge.svg)](https://github.com/github/entitlements-github-plugin/actions/workflows/lint.yml) [![release](https://github.com/github/entitlements-github-plugin/actions/workflows/release.yml/badge.svg)](https://github.com/github/entitlements-github-plugin/actions/workflows/release.yml) [![build](https://github.com/github/entitlements-github-plugin/actions/workflows/build.yml/badge.svg)](https://github.com/github/entitlements-github-plugin/actions/workflows/build.yml) [![coverage](https://img.shields.io/badge/coverage-100%25-success)](https://img.shields.io/badge/coverage-100%25-success) [![style](https://img.shields.io/badge/code%20style-rubocop--github-blue)](https://github.com/github/rubocop-github)

`entitlements-github-plugin` is an [entitlements-app](https://github.com/github/entitlements-app) plugin allowing entitlements configs to be used to manage membership of GitHub.com Organizations and Teams.

## Usage

Your `entitlements-app` config `config/entitlements.yaml` runs through ERB interpretation automatically. You can extend your entitlements configuration to load plugins like so:

```ruby
<%-
  unless ENV['CI_MODE']
    begin
      require_relative "/data/entitlements/lib/entitlements-and-plugins"
    rescue Exception
      begin
        require_relative "lib/entitlements-and-plugins"
      rescue Exception
        # We might not have the plugins installed and still want this file to be
        # loaded. Don't raise anything but silently fail.
      end
    end
  end
-%>
```

You can then define `lib/entitlements-and-plugins` like so:

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

ENV["BUNDLE_GEMFILE"] = File.expand_path("../../Gemfile", File.dirname(__FILE__))
require "bundler/setup"
require "entitlements"

# require entitlements plugins here
require "entitlements/backend/github_org"
require "entitlements/backend/github_team"
require "entitlements/service/github"
```

Any plugins defined in `lib/entitlements-and-plugins` will be loaded and used at `entitlements-app` runtime.

## Features

### Org Team

`entitlements-github-plugin` manages org team membership to two roles - `admin` and `member`. Your `entitlements-app` config `config/entitlements.yaml` is used to configure the location for the declarations of this membership.

```ruby
  github.com/github/org:
    addr: <%= ENV["GITHUB_API_BASE"] %>
    base: ou=org,ou=github,ou=GitHub,dc=github,dc=com
    dir: github.com/github/org
    org: github
    token: <%= ENV["GITHUB_ORG_TOKEN"] %>
    type: "github_org"
```

`entitlements-github-plugin` will look in the defined location above, `github.com/github/org`, for `admin.txt` and `member.txt` defining the respective membership for each role.

### GitHub Teams

`entitlements-github-plugin` manages membership for all teams listed in the defined subfolder. The plugin will use extension-less name of the file as the team name. GitHub Team management can be configured like so:

```ruby
  github.com/github/teams:
    addr: <%= ENV["GITHUB_API_BASE"] %>
    base: ou=teams,ou=github,ou=GitHub,dc=github,dc=com
    dir: github.com/github/teams
    org: github
    token: <%= ENV["GITHUB_ORG_TOKEN"] %>
    type: "github_team"
```

For example, if there were a file `github.com/github/teams/new-team.txt` with a single user inside, a GitHub.com Team would be created in the `github` org with the name `new-team`.

#### Metadata

Entitlements configs can contain metadata which the plugin will use to make further configuration decisions.

`metadata_parent_team_name` - when defined in an entitlements config, the defined team will be made the parent team of this GitHub.com Team.

## Release 🚀

To release a new version of this Gem, do the following:

1. Update the version number in the [`lib/version.rb`](lib/version.rb) file
2. Run `bundle install` to update the `Gemfile.lock` file with the new version
3. Commit your changes, push them to GitHub, and open a PR

Once your PR is approved and the changes are merged, a new release will be created automatically by the [`release.yml`](.github/workflows/release.yml) workflow. The latest version of the Gem will be published to the GitHub Package Registry.
