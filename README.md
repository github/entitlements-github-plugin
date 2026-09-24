# entitlements-github-plugin

[![acceptance](https://github.com/github/entitlements-github-plugin/actions/workflows/acceptance.yml/badge.svg)](https://github.com/github/entitlements-github-plugin/actions/workflows/acceptance.yml) [![test](https://github.com/github/entitlements-github-plugin/actions/workflows/test.yml/badge.svg)](https://github.com/github/entitlements-github-plugin/actions/workflows/test.yml) [![lint](https://github.com/github/entitlements-github-plugin/actions/workflows/lint.yml/badge.svg)](https://github.com/github/entitlements-github-plugin/actions/workflows/lint.yml) [![release](https://github.com/github/entitlements-github-plugin/actions/workflows/release.yml/badge.svg)](https://github.com/github/entitlements-github-plugin/actions/workflows/release.yml) [![build](https://github.com/github/entitlements-github-plugin/actions/workflows/build.yml/badge.svg)](https://github.com/github/entitlements-github-plugin/actions/workflows/build.yml) [![coverage](https://img.shields.io/badge/coverage-100%25-success)](https://img.shields.io/badge/coverage-100%25-success) [![style](https://img.shields.io/badge/code%20style-rubocop--github-blue)](https://github.com/github/rubocop-github)

`entitlements-github-plugin` is an [entitlements-app](https://github.com/github/entitlements-app) plugin allowing entitlements configs to manage GitHub organization and team membership, and direct repository access.

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
require "entitlements/backend/github_repository"
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
    ignore_not_found: false # optional argument to ignore users who are not found in the GitHub instance
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
    ignore_not_found: false # optional argument to ignore users who are not found in the GitHub instance
    type: "github_team"
```

For example, if there were a file `github.com/github/teams/new-team.txt` with a single user inside, a GitHub.com Team would be created in the `github` org with the name `new-team`.

#### Metadata

Entitlements configs can contain metadata which the plugin will use to make further configuration decisions.

`metadata_parent_team_name` - when defined in an entitlements config, the defined team will be made the parent team of this GitHub.com Team.

### GitHub repositories

The `github_repository` backend manages **direct, user-only repository grants for active, non-owner organization members**. It does not create or delete repositories. Load `entitlements/backend/github_repository` in your plugin loader and add this entry under `groups`:

```yaml
github.com/github/repositories:
  type: github_repository
  dir: repositories/github
  base: ou=repositories,ou=github,ou=GitHub,dc=github,dc=com
  org: github
  token: <%= ENV.fetch("GITHUB_REPOSITORY_TOKEN") %>
  addr: <%= ENV["GITHUB_API_BASE"] %>
  allowed_types: [txt]
  allowed_methods: [username, group]
  features: [add, update, remove]
  ignore: []
  ignore_not_found: false
```

`dir`, `base`, `org`, and `token` are required, nonempty strings. Relative directories resolve against Entitlements' `configuration_path`. Omit `addr` (or set it to null) for GitHub.com. For GitHub Enterprise Server, use `https://HOST/api/v3`; repository GraphQL requests use `https://HOST/api/graphql`. The server must support collaborator permission sources and source-specific role names.

#### Repository and role files

Each immediate subdirectory opts one repository into management:

```text
repositories/github/
  entitlements-app/
    read.txt
    write.txt
    maintain.txt
  another.repository/
    admin.txt
```

Role files use standard Entitlements syntax, not bare lists of logins. For example, `entitlements-app/write.txt`:

```text
username = alice
username = bob; expiration = 2027-01-01
group = engineering/platform
```

Group references, filters, and expiration are evaluated by the normal Entitlements rules engine. People must resolve through the configured people data source, with their `uid` equal to their GitHub login. As with other backends, the underlying username rule omits people absent from that data source; validate such references in your configuration CI. `ignore_not_found` applies to evaluated people missing active GitHub organization membership, not to missing repositories or API failures.

YAML and Ruby role files are also supported when enabled in `allowed_types`, e.g. `[txt, yaml, rb]`. If omitted, all three formats are allowed. Ruby files use the standard Entitlements Ruby rule-class convention (repository directory and role filename determine the class); enable them only for trusted configuration authors. `allowed_methods` constrains declarative rules, not arbitrary Ruby code.

| Role filename (without extension) | REST permission |
|----------------------------------|-----------------|
| `read` | `pull` |
| `triage` | `triage` |
| `write` | `push` |
| `maintain` | `maintain` |
| `admin` | `admin` |

Custom roles are not supported. Unsupported direct roles or incomplete API responses abort reconciliation rather than falling back to effective permissions. A user cannot occur in multiple roles, even with different capitalization. Comparisons are case-insensitive; difference logs preserve login capitalization and show old and new roles. Duplicate role files, unsupported extensions, symlinks, nested directories, and unexpected files (including README and hidden files) are rejected. Keep documentation outside the managed root.

**A missing role file means no desired direct members for that role.** An empty repository directory therefore requests removal of all managed direct grants if `remove` is enabled. To keep an explicitly empty role file, use the standard `metadata_no_conditions_ok = true` text directive. **Deleting the entire repository directory opts that repository out without cleanup**; existing access is untouched. The configured root must still exist. Git does not track empty directories, so keep an explicit empty role file when intending to remove every managed grant.

#### Ownership boundary and feature flags

Only a `Repository` permission source is used to determine a current direct role, even when a team or organization gives the person a higher effective permission. Team, organization, enterprise-team, and owner grants are not managed. Outside collaborators and organization owners are excluded entirely; desired owners and non-members fail validation by default. With `ignore_not_found: true`, they are skipped with a warning. This backend does not invite people into the organization or manage pending organization invitations.

`ignore` is an array of logins removed from both sides of the diff, case-insensitively. Ignored users' grants are never mutated. Ignoring a user does not bypass schema/response validation when reading the repository. No fallback to effective permissions is performed.

`features` defaults to `[add, update, remove]`. `add` permits new direct grants, `update` permits role changes, and `remove` permits deleting direct grants absent from desired state. Disabled operations are suppressed in both actions and displayed state. `features: []` performs reads and validation but produces no changes. To inspect the full proposed diff without applying it, use Entitlements' no-op mode with all features enabled.

Role changes issue one `PUT`, never a remove followed by an add. All upserts for a repository precede removals. Removing a direct grant does not remove inherited access; it also has GitHub's documented side effects on forks and other resources. Review the [collaborator API documentation](https://docs.github.com/en/rest/collaborators/collaborators) before enabling removal. GitHub may reject a direct role below organization base permissions.

#### GitHub App permissions and validation gate

Install the App on every managed repository with:

| Scope | Permission | Use |
|-------|------------|-----|
| Repository | **Administration: write** | Add, change, and remove collaborator grants |
| Repository | **Metadata: read** (automatically granted) | Repository visibility |
| Organization | **Members: read** | Active organization members and owners |

These REST requirements are listed in [GitHub's App permission reference](https://docs.github.com/en/rest/authentication/permissions-required-for-github-apps). Repository reads require access to `collaborators(affiliation: DIRECT)`, `permissionSources`, and each direct source's `roleName`; see the [GraphQL schema](https://docs.github.com/en/graphql/reference/repos). **Live installation-token access to these fields has not been validated by the unit suite.** Before deploying, verify it using the actual App installation and GitHub/GHES version. If those fields are unavailable, do not enable mutations or substitute effective REST permissions.

A live GitHub.com probe with a classic OAuth token confirmed that `permissionSources` and `roleName` require the `admin:org` scope; `repo` plus `read:org` was rejected. This is a classic-token scope requirement, not evidence that an App installation token has access. Validate the App separately rather than broadening an operator's token automatically.

In a designated disposable repository, give an active organization member a direct role and a different, higher inherited role. Verify the direct source reports the lower role, then add/change/remove the direct grant using the installation token. Expect `204` for organization-member adds, updates, and removals. `201` indicates an invitation rather than active access; the backend warns and does not cache it as a completed grant. Confirm inherited and outside access remain unchanged and a subsequent run has no diff. Do not run this check against production accounts or repositories.

#### API usage, failure behavior, and rollout

Repository reads use one GraphQL request per page of up to 100 direct collaborators, at least one per managed repository. Pagination follows `hasNextPage` and rejects missing/repeated cursors. Snapshots are cached in memory for the service's lifetime and invalidated after successful or partial applies. There is no persistent repository cache or `entitlements-caches` integration.

Organization membership uses the shared per-run cache (paginated REST reads for `admin` and `member`, 100 users per page); predictive membership is refreshed before authorizing repository grants. Each added or changed grant requires one REST `PUT`, and each removed grant one `DELETE`, excluding retries. Octokit's existing middleware retries server errors on idempotent mutations; authorization, validation, and abuse/rate-limit responses abort without application-level retries. GraphQL uses the shared bounded retry transport. A partial failure stops application, leaves already-applied grants in place, and invalidates the snapshot. Re-run after resolving the failure; changes are not rolled back automatically.

1. Complete the disposable-repository App validation above.
2. Start with a small set of repository directories and no-op mode; compare direct roles with repository settings. `features: []` is also safe for read/validation checks but suppresses the diff.
3. Enable only `add` and `update`, then confirm successive runs converge.
4. Review ignored accounts, inherited access, and outside collaborators before enabling `remove`.
5. Expand gradually while measuring GraphQL cost, REST rate usage, runtime, and failure rates. Consider persistent caching only if measurements justify it.

Production convergence and API budgets require this live rollout; mocked tests do not establish them.

## Release 🚀

To release a new version of this Gem, do the following:

1. Update the version number in the [`lib/version.rb`](lib/version.rb) file
2. Run `bundle install` to update the `Gemfile.lock` file with the new version
3. Commit your changes, push them to GitHub, and open a PR

Once your PR is approved and the changes are merged, a new release will be created automatically by the [`release.yml`](.github/workflows/release.yml) workflow. The latest version of the Gem will be published to the GitHub Package Registry and RubyGems.
