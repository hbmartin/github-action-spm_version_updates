# Upgrade guide: v1.2.0 to v2.0.0

This guide covers the public changes between the `v1.2.0` and `v2.0.0`
release tags. Most GitHub Action users only need to change the action ref and
remove `fail-on-updates` if they were still using it. Most Danger plugin users
who only call `spm_version_updates.check_for_updates` or
`spm_version_updates.check_manifests` can upgrade without changing their
Dangerfile.

`v2.0.0` is still a major release because it removes legacy compatibility APIs
and makes the core Ruby checker return structured results instead of legacy
warning strings.

## Quick checklist

1. Change action workflows from `@v1` or `@v1.2.0` to `@v2` or `@v2.0.0`.
2. Replace `fail-on-updates: true` with `fail-on: true` or `fail-on: any`.
3. If you use the `danger-spm_version_updates` gem, update Bundler so both
   `danger-spm_version_updates` and `spm_version_updates` resolve to `2.0.0`.
4. If you call `SpmChecker` directly, update callers to use
   `result.updates` and `result.parse_warnings`.
5. If you required deprecated Danger helper files such as
   `spm_version_updates/git`, switch to the core gem modules listed below.
6. Decide whether the new action-only features apply to your workflow:
   `package-resolved-paths` as a standalone source mode,
   `allow-missing-resolved`, `apply-updates`, `enrich-release-notes`, and
   `version-lookup-workers`.
7. Run the upgraded workflow on a branch and review the step summary, outputs,
   PR comment, and any generated workspace diff.

## Breaking changes

### GitHub Action

The `fail-on-updates` input has been removed. Use `fail-on` for both the old
"fail on any report" behavior and semantic thresholds:

```yaml
# v1.2.0
- uses: hbmartin/github-action-spm_version_updates@v1.2.0
  with:
    package-manifest-paths: Package.swift
    fail-on-updates: true

# v2.0.0
- uses: hbmartin/github-action-spm_version_updates@v2.0.0
  with:
    package-manifest-paths: Package.swift
    fail-on: any
```

`fail-on` accepts:

| Value | Meaning |
| --- | --- |
| `any` or `true` | Fail when any update report exists, including branch and revision reports. |
| `major` | Fail on major semantic-version updates. |
| `minor` | Fail on major or minor semantic-version updates. |
| `patch` | Fail on any semantic-version update. |
| empty, `false`, or `none` | Never fail because of reported updates. |

No action outputs were removed.

### Danger plugin

No Dangerfile configuration accessors were removed between `v1.2.0` and
`v2.0.0`. These plugin calls remain valid:

```ruby
spm_version_updates.check_when_exact = true
spm_version_updates.check_branches = true
spm_version_updates.check_revisions = false
spm_version_updates.report_above_maximum = true
spm_version_updates.report_pre_releases = false
spm_version_updates.ignore_repos = ["https://github.com/example/private-tool"]
spm_version_updates.repo_rules_path = ".github/spm-version-rules.yml"

spm_version_updates.check_for_updates("MyApp.xcodeproj")
spm_version_updates.check_manifests(["Package.swift"])
```

The removed Danger-related surface is the old helper shim files that existed
for callers written against much older releases:

| Removed require | Replacement |
| --- | --- |
| `require "spm_version_updates/git"` | `require "spm_version_updates/git_operations"` and call `GitOperations`. |
| `require "spm_version_updates/xcode"` | `require "spm_version_updates/xcode_parser"` or `require "spm_version_updates/xcode_project_package_reader"`. |
| `require "spm_version_updates/gem_version"` | `require "spm_version_updates/version"`. |

Normal Dangerfiles that only use the `spm_version_updates` plugin object do not
use those files.

### Core Ruby API

Direct `SpmChecker` callers must update for the new return value. In `v1.2.0`,
`check_for_updates` and `check_manifests` returned an array of warning strings
and exposed structured details through checker readers:

```ruby
warnings = checker.check_manifests(["Package.swift"])
warnings.each { |warning| puts warning }
checker.warning_details.each { |detail| p detail }
checker.parse_warnings.each { |record| p record }
```

In `v2.0.0`, checker methods return a `SpmChecker::Result`:

```ruby
result = checker.check_manifests(["Package.swift"])
result.updates.each { |update| puts update["message"] }
result.updates.each { |update| p update }
result.parse_warnings.each { |record| p record }
```

The result records are string-keyed hashes. The legacy `warning_details` reader,
the legacy `parse_warnings` checker reader, and the legacy string-array return
value were removed.

If direct code referenced `SpmChecker::VERSION_TAG_WORKER_COUNT`, switch to the
runtime setting:

```ruby
checker.version_lookup_workers = 4
```

## GitHub Action upgrade

### Source modes

`v1.2.0` required exactly one of `xcode-project-path` or
`package-manifest-paths`. `package-resolved-paths` was only an override for
manifest mode.

`v2.0.0` has three source modes:

| Mode | Inputs | Notes |
| --- | --- | --- |
| Xcode project | `xcode-project-path` | Cannot be combined with `package-manifest-paths` or `package-resolved-paths`. |
| Swift manifest | `package-manifest-paths`, optional `package-resolved-paths` | `package-resolved-paths` still overrides the inferred adjacent `Package.resolved` files. |
| Package.resolved only | `package-resolved-paths` without the other source inputs | Checks committed pins directly without parsing manifests or an Xcode project. |

Package.resolved-only mode reports version pins as `requirement_kind:
"resolvedPin"`. Revision-only pins stay quiet unless `check-revisions: true`.

### Newly available action inputs

| Input | Default | Use it when |
| --- | --- | --- |
| `version-lookup-workers` | `4` | You need to raise or lower concurrent git tag lookups. `v1.2.0` used a fixed worker count. |
| `allow-missing-resolved` | `false` | Missing `Package.resolved` files should appear as warnings instead of failing the run. |
| `apply-updates` | `false` | You want the action to rewrite supported `Package.swift` requirements before a separate PR-creation step runs. |
| `enrich-release-notes` | `true` | GitHub release notes should be included in PR comments or tracking issues for supported GitHub dependencies. Set `false` to skip those GitHub API calls. |

`package-resolved-paths` is not a new input, but it has new standalone behavior
when supplied without `xcode-project-path` or `package-manifest-paths`.

### Removed action inputs

| Removed input | Replacement |
| --- | --- |
| `fail-on-updates` | `fail-on: any` or `fail-on: true`. |

### New action outputs

| Output | Meaning |
| --- | --- |
| `missing-resolved` | Number of missing resolved files reported when `allow-missing-resolved: true`. |
| `applied-updates` | Number of manifest requirement rewrites applied when `apply-updates: true`. |
| `applied-updates-json` | JSON array of the applied update records. Empty when apply mode is off or nothing was applied. |

The existing outputs are still present: `updates-found`,
`major-updates-found`, `minor-updates-found`, `patch-updates-found`,
`parse-warnings`, `updates-json`, `blocked`, `error-message`,
`tracking-issue-number`, and `tracking-issue-url`.

### Apply mode

`apply-updates: true` is action-only. It rewrites `Package.swift` files in the
checked-out workspace and does not create a pull request on its own. Pair it
with a normal PR creation action:

```yaml
permissions:
  contents: write
  pull-requests: write

steps:
  - uses: actions/checkout@v4
  - id: spm
    uses: hbmartin/github-action-spm_version_updates@v2.0.0
    with:
      package-manifest-paths: Package.swift
      apply-updates: "true"
      fail-on: ""
  - uses: peter-evans/create-pull-request@v7
    with:
      branch: spm-version-updates
      title: Update Swift package requirements
      commit-message: Update Swift package requirements
```

Apply mode requires manifest mode. Combining `apply-updates: true` with
`xcode-project-path` or Package.resolved-only mode fails the run with a
configuration error, because there is no supported `Package.swift` requirement
rewrite to make in those modes. Within manifest mode it skips branch, revision,
above-maximum, and unsupported records. If a rewrite fails after other files
were changed, the action reports the partial result and exits non-zero so the
workspace diff is visible.

### Release-note enrichment

Release-note enrichment is action-only and enabled by default. It uses the
GitHub API through the configured `github-token`, looks up GitHub releases for
reported GitHub-hosted dependencies, and renders found notes in collapsed
details blocks in comments and tracking issues.

Set `enrich-release-notes: false` when you want shorter comments, want to avoid
extra GitHub API traffic, or use a token that should not read release metadata.

### Missing resolved files

In `v1.2.0`, missing manifest-mode `Package.resolved` files always failed the
run. `v2.0.0` keeps that default. If you opt into
`allow-missing-resolved: true`, the action continues with the resolved files
that exist and reports the missing paths in the step summary, comments, and the
`missing-resolved` output.

Use this only when an incomplete report is acceptable. For merge-blocking
dependency checks, leaving the default failure behavior is usually safer.

### Runtime and reporting changes

- When `xcode-project-path` is empty, setup skips the `xcodeproj` dependency.
  That now includes both manifest mode and Package.resolved-only mode.
- `updates-json` remains the machine-readable update list and may now include
  `requirement_kind: "resolvedPin"` for Package.resolved-only reports.
- GitHub comments and step summaries include missing-resolved and applied-update
  sections when those features are used.
- Unexpected-error backtraces print only when `DEBUG=true`.

## Danger plugin upgrade

Update the gem version through Bundler:

```sh
bundle update danger-spm_version_updates spm_version_updates
```

The plugin still reports through Danger `warn` calls. It does not expose GitHub
Action outputs, PR comment management, tracking issues, release-note
enrichment, action caching, apply mode, or `fail-on`.

### Danger options

No new Dangerfile accessors were added and none were removed in `v2.0.0`.

| Danger accessor | Action input with similar behavior |
| --- | --- |
| `check_when_exact` | `check-when-exact` |
| `check_branches` | `check-branches` |
| `check_revisions` | `check-revisions` |
| `report_above_maximum` | `report-above-maximum` |
| `report_pre_releases` | `report-pre-releases` |
| `ignore_repos` | `ignore-repos` |
| `repo_rules_path` | `repo-rules-path` |

The following `v2.0.0` capabilities are not Danger plugin options:

| Capability | Danger plugin status |
| --- | --- |
| Package.resolved-only source mode | Not exposed by the plugin wrapper. Use the core gem's `check_resolved` directly if needed. |
| `allow-hosts` | Not exposed as a Danger accessor. Use the core gem directly for host allow-list enforcement. |
| `version-lookup-workers` | Not exposed as a Danger accessor. Use the core gem directly for custom worker counts. |
| `allow-missing-resolved` | Not exposed as a Danger accessor. Use the core gem's `missing_resolved_handler` directly if needed. |
| `apply-updates` | Action-only. The core gem exposes `ManifestUpdater` for custom Ruby workflows. |
| `enrich-release-notes` | Action-only. |
| `fail-on`, comments, tracking issues, outputs, cache inputs, `setup-ruby`, `github-token` | Action-only. |

## Core gem and custom Ruby workflows

The core gem keeps the existing checker configuration accessors and adds:

| API | Purpose |
| --- | --- |
| `SpmChecker#check_resolved(paths)` | Check one or more `Package.resolved` files directly. |
| `SpmChecker#version_lookup_workers=` | Configure concurrent version tag lookup workers. |
| `SpmChecker#missing_resolved_handler=` | Handle missing resolved files and continue with existing paths. |
| `PackageResolved.pins_from(path)` | Read structured pin records from a resolved file. |
| `ManifestUpdater.rewrite(content, updates)` and `ManifestUpdater.update_file(path, updates)` | Rewrite supported manifest requirements from structured update records. |

The Ruby requirement remains `>= 3.2`.

## Full option matrix

| Capability | GitHub Action | Danger plugin |
| --- | --- | --- |
| Xcode project source | `xcode-project-path` | `check_for_updates("App.xcodeproj")` |
| Manifest source | `package-manifest-paths` | `check_manifests(["Package.swift"])` |
| Explicit resolved paths with manifests | `package-resolved-paths` | second `check_manifests` argument |
| Package.resolved-only source | `package-resolved-paths` alone | No plugin option; core `check_resolved` only |
| Exact pins | `check-when-exact` | `check_when_exact` |
| Branch pins | `check-branches` | `check_branches` |
| Revision pins | `check-revisions` | `check_revisions` |
| Above-maximum reports | `report-above-maximum` | `report_above_maximum` |
| Pre-release reports | `report-pre-releases` | `report_pre_releases` |
| Skip repositories | `ignore-repos` | `ignore_repos` |
| Per-repository suppression rules | `repo-rules-path` | `repo_rules_path` |
| Host allow-list | `allow-hosts` | No plugin option |
| Worker count | `version-lookup-workers` | No plugin option |
| Missing resolved files as warnings | `allow-missing-resolved` | No plugin option |
| Apply manifest updates | `apply-updates` | No plugin option |
| GitHub release notes | `enrich-release-notes` | No plugin option |
| Fail the CI job on updates | `fail-on` | Use normal Danger failure policy in your Dangerfile |
| PR comments, tracking issues, step summary, outputs, annotations | Built in | Danger handles report publishing |
| Runtime setup | `setup-ruby` | Managed by your Danger job |
| GitHub token | `github-token` | Managed by Danger or your CI |

## Validation checklist

After upgrading, verify one pull request run and check:

1. The action or Danger step installs version `2.0.0`.
2. The selected source mode is shown correctly in logs.
3. The update count in the logs matches the PR comment or Danger warnings.
4. `fail-on` behavior matches the old workflow if you migrated from
   `fail-on-updates`.
5. Downstream steps that read outputs still use `always()` when `fail-on` can
   intentionally fail the action.
6. If `apply-updates` is enabled, the generated `Package.swift` diff is the one
   you expect before allowing the PR creation step to run on protected branches.
