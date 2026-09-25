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

The `github_repository` backend manages **individual-only repository-local grants**, preserving organization-wide access. Role files define the desired direct grants; undeclared direct user grants (including outside collaborators) and **direct organization-team repository associations** are removed when `remove` is enabled. Active organization members, including owners, are valid desired users. Owner grants and requested roles below inherited organization-wide access are explicitly deferred as described below, not silently treated as satisfied direct grants. It does not create or delete repositories. Load `entitlements/backend/github_repository` in your plugin loader and add this entry under `groups`:

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

`dir`, `base`, `org`, and `token` are required, nonempty strings. Relative directories resolve against Entitlements' `configuration_path`. Omit `addr` (or set it to null) for GitHub.com. For GitHub Enterprise Server, use `https://HOST/api/v3`; repository GraphQL requests use `https://HOST/api/graphql`. The server must expose collaborator permission sources, source-specific role names, repository-team `access_source`, organization base permissions, and the organization-role catalog and assignments. Missing data or unsupported APIs abort reconciliation; there is no assumption that unavailable inherited-access information means no inherited access.

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

Group references, filters, and expiration are evaluated by the normal Entitlements rules engine. Group references expand to individual users, never GitHub team grants. People must resolve through the configured people data source, with their `uid` equal to their GitHub login. As with other backends, the underlying username rule omits people absent from that data source; validate such references in your configuration CI. `ignore_not_found` applies to evaluated people missing active GitHub organization membership, not to missing repositories or API failures.

YAML and Ruby role files are also supported when enabled in `allowed_types`, e.g. `[txt, yaml, rb]`. If omitted, all three formats are allowed. Ruby files use the standard Entitlements Ruby rule-class convention (repository directory and role filename determine the class); enable them only for trusted configuration authors. `allowed_methods` constrains declarative rules, not arbitrary Ruby code.

| Role filename (without extension) | REST permission |
|----------------------------------|-----------------|
| `read` | `pull` |
| `triage` | `triage` |
| `write` | `push` |
| `maintain` | `maintain` |
| `admin` | `admin` |

Custom direct repository roles are not supported. Organization roles, including custom and enterprise-defined organization roles, are discovered dynamically without a role-name allowlist. Their `base_role` determines their inherited repository level; roles with no repository base still retain their organization capabilities and are reported without inventing a repository permission. Unsupported direct roles, unknown repository base roles, or incomplete API responses abort reconciliation rather than falling back to effective permissions. A user cannot occur in multiple roles, even with different capitalization. Comparisons are case-insensitive; difference logs preserve login capitalization and show old and new roles. Duplicate role files, unsupported extensions, symlinks, nested directories, and unexpected files (including README and hidden files) are rejected. Keep documentation outside the managed root.

**A missing role file means no desired direct members for that role.** An empty repository directory therefore requests removal of all managed direct user and team grants if `remove` is enabled. To keep an explicitly empty role file, use the standard `metadata_no_conditions_ok = true` text directive. **Deleting the entire repository directory opts that repository out without cleanup**; existing access is untouched. The configured root must still exist. Git does not track empty directories, so keep an explicit empty role file when intending to remove every managed grant.

#### Ownership boundary and feature flags

For non-owners, only a `Repository` permission source determines a current direct user role, even when a team or organization gives the person higher effective access. Non-member direct grants are included in cleanup. Desired non-members fail validation by default; with `ignore_not_found: true`, they are ignored with a warning. Owners do not require this workaround. This backend does not invite people into the organization or manage pending organization invitations.

Organization-wide access is read from live organization membership, `default_repository_permission`, and **every role and its user assignments** from the Organization Roles API, including direct, indirect/team-derived, and mixed assignments. All-repository read/triage/write/maintain/admin, security-manager, and custom/enterprise-defined organization roles follow the same metadata-driven path. No organization role or assignment is modified.

An upsert below the highest inherited organization repository level is logged as `DEFER`; the desired declaration is retained, but the current direct grant is left unchanged. This avoids base-permission API rejection and does not invent a higher desired role. Equal or higher direct roles can be provisioned normally. Undeclared non-owner direct grants can still be removed: their organization-wide access remains. A deferral is a policy exception, not full convergence to the role files, and can leave an existing higher direct grant in place until reviewed or the inherited role expires.

Owners require an additional representation safeguard: GitHub can emit a synthetic `Repository` admin source for organization ownership, including alongside a real direct source. All direct-user reconciliation for current owners is deferred because these sources cannot safely be distinguished. The backend does not delete apparent owner grants or claim to downgrade owner access. After JIT ownership or another blocking organization role expires, a new calculation resumes the declared direct-grant reconciliation. This is periodic reconciliation, not an atomic JIT handoff; access can change between runs.

Every managed repository opts into removal of team associations explicitly reported with `access_source: direct`, including empty teams. Entries reported as `organization` or `enterprise` are preserved and logged. A team with both a direct repository association and an organization role can lose its direct association while retaining inherited access. Missing/unknown source metadata is an error, never a reason to guess that access is direct. Enterprise-team associations are outside this backend's writable scope; their presence is explicitly reported as an unmanaged policy exception. There is no team manifest or team allowlist. Team membership, hierarchy, organization roles, and access to other repositories remain unchanged. Parent direct associations are removed before child direct associations, with a fresh source check before each deletion.

Organization-wide privileges and public/internal repository visibility remain unchanged. Removing repository-local grants does not necessarily remove all of a person's effective access. Public repositories remain publicly readable.

`ignore` is an array of logins removed from both sides of the diff, case-insensitively. Ignored users' grants are never mutated. Ignoring a user does not bypass schema/response validation when reading the repository. No fallback to effective permissions is performed.

`features` defaults to `[add, update, remove]`. `add` permits new direct grants, `update` permits role changes, and `remove` permits deleting undeclared direct users and all repository team associations. Disabled operations are suppressed in both actions and displayed state. If removals are disabled while teams remain, the backend warns that individual-only grants are not enforced. `features: []` performs reads and validation but produces no changes. Feature restrictions and ignored users are policy exceptions; use all features and an empty ignore list for authoritative enforcement. To inspect the full proposed diff without applying it, use Entitlements' no-op mode with all features enabled.

Role changes issue one `PUT`, never a remove followed by an add. All desired user upserts for a repository precede user and team removals. Removing grants has GitHub's documented side effects on forks and other resources. Review the [collaborator API documentation](https://docs.github.com/en/rest/collaborators/collaborators) before enabling removal. GitHub may reject a direct role below organization base permissions.

#### GitHub App permissions and validation gate

Install the App on every managed repository with:

| Scope | Permission | Use |
|-------|------------|-----|
| Repository | **Administration: write** | Add, change, and remove collaborator grants; remove team repository associations |
| Repository | **Metadata: read** (automatically granted) | Repository visibility |
| Organization | **Members: read** | Active organization members, owners, repository teams, and organization-role user assignments |
| Organization | **Administration: read** | Organization base repository permission and permission-source visibility |
| Organization | **Custom organization roles: read** | Complete organization-role catalog, including predefined and enterprise-defined roles |

These REST requirements are listed in [GitHub's App permission reference](https://docs.github.com/en/rest/authentication/permissions-required-for-github-apps). Repository reads require access to `collaborators(affiliation: DIRECT)`, `permissionSources`, and each direct source's `roleName`; see the [GraphQL schema](https://docs.github.com/en/graphql/reference/repos). **Live installation-token access to these fields has not been validated by the unit suite.** Before deploying, verify it using the actual App installation and GitHub/GHES version. If those fields are unavailable, do not enable mutations or substitute effective REST permissions.

A live GitHub.com probe with a classic OAuth token confirmed that `permissionSources` and `roleName` require the `admin:org` scope; `repo` plus `read:org` was rejected. This is a classic-token scope requirement, not evidence that an App installation token has access. Validate the App separately rather than broadening an operator's token automatically.

The backend deliberately does not request the unused effective `permission` field. A live CI calculation with an `admin:org`-only token showed that field requires an additional `public_repo` scope. Exact direct roles come from `permissionSources.roleName`, so requesting effective permissions would add an unnecessary credential requirement.

In a designated disposable organization/repository, cover owners/JIT transitions, each all-repository base role, security-manager and custom role assignments (direct and through teams), organization base permissions, an undeclared outside collaborator, and empty/nested teams. Include a team with both direct and organization-wide access. Verify reads using the actual installation token, then reconcile repository-local grants. Expect `204` for user upserts/removals and team association removals. `201` indicates an invitation rather than active access; post-apply verification must not mistake it for convergence. Confirm organization-wide privileges, team memberships and other repositories remain unchanged, manageable undeclared grants disappear, and subsequent runs show either no diff or explicit deferrals. Do not run this mutation check against production accounts or repositories.

#### API usage, failure behavior, and rollout

Repository reads use one GraphQL request per page of up to 100 direct collaborators, plus paginated REST repository-team reads (100 per page). GraphQL pagination follows `hasNextPage` and rejects missing/repeated cursors; team reads use Octokit's automatic Link pagination. Snapshots include team identities and hierarchy independently of user membership. Snapshots are cached in memory for the service's lifetime and invalidated after successful or partial applies. There is no persistent repository cache or `entitlements-caches` integration.

Before application, a fresh snapshot must match the calculated existing state (excluding ignored users), including organization membership, base permissions, role definitions and assignments; otherwise the backend aborts and requires recalculation. After application, another fresh snapshot must match the feature-controlled, deferral-aware target state. Team comparisons use only direct associations, so inherited access persisting after direct removal is not a false convergence failure. Residual manageable grants or partial failures are explicit errors. Deferrals remain visible policy exceptions. These checks detect drift but are not an atomic transaction with GitHub; concurrent administrators can still change access during a run.

Organization access is cached per service/installation during calculation, not shared with other backends' predictive/JIT membership caches. Reads include paginated REST membership, organization settings, the complete role catalog, and paginated user assignments for every role. It is refreshed before and after each repository apply; membership/role changes may require recalculation even if repository grants did not change. Each added or changed grant requires one REST `PUT`, and each removed grant one `DELETE`, excluding retries. Octokit's existing middleware retries server errors on idempotent mutations; authorization, validation, and abuse/rate-limit responses abort without application-level retries. GraphQL uses the shared bounded retry transport. A partial failure stops application, leaves already-applied grants in place, and invalidates the snapshot. Re-run after resolving the failure; changes are not rolled back automatically.

1. Complete the disposable-repository App validation above.
2. Start with a small set of repository directories and no-op mode; compare direct roles with repository settings. `features: []` is also safe for read/validation checks but suppresses the diff.
3. Enable only `add` and `update`, then confirm successive runs converge.
4. Review ignored accounts, organization-level access, outside collaborators, and all repository team associations before enabling `remove`. Existing team-based write/admin access will be removed even when team members are declared individually.
5. Expand gradually while measuring GraphQL cost, REST rate usage, runtime, and failure rates. Consider persistent caching only if measurements justify it.

Production convergence and API budgets require this live rollout; mocked tests do not establish them.

## Release 🚀

To release a new version of this Gem, do the following:

1. Update the version number in the [`lib/version.rb`](lib/version.rb) file
2. Run `bundle install` to update the `Gemfile.lock` file with the new version
3. Commit your changes, push them to GitHub, and open a PR

Once your PR is approved and the changes are merged, a new release will be created automatically by the [`release.yml`](.github/workflows/release.yml) workflow. The latest version of the Gem will be published to the GitHub Package Registry and RubyGems.
