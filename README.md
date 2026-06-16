# Swift Package Version Updates GitHub Action

[![CI](https://github.com/hbmartin/github-action-spm_version_updates/actions/workflows/lint_and_test.yml/badge.svg)](https://github.com/hbmartin/github-action-spm_version_updates/actions/workflows/lint_and_test.yml)
[![CodeFactor](https://www.codefactor.io/repository/github/hbmartin/github-action-spm_version_updates/badge/main)](https://www.codefactor.io/repository/github/hbmartin/github-action-spm_version_updates/overview/main)
[![Release](https://img.shields.io/github/v/release/hbmartin/github-action-spm_version_updates?sort=semver&logo=github)](https://github.com/hbmartin/github-action-spm_version_updates/releases)
[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-Swift%20Package%20Version%20Updates-blue?logo=githubactions&logoColor=white)](https://github.com/marketplace/actions/spm-version-updates)
[![Gem Version](https://img.shields.io/gem/v/danger-spm_version_updates?logo=rubygems&label=danger%20plugin)](https://rubygems.org/gems/danger-spm_version_updates)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Automatically detect and report available updates for your Swift Package Manager (SPM) dependencies — runnable as a standalone **GitHub Action**, a **Danger plugin**, or a **Ruby gem** (for example, in a Fastlane lane).

🚀 **Fast, lightweight, and works without Swift or Xcode installed on your CI runner** — it parses your manifests directly and checks each dependency with `git ls-remote`, so there's no macOS runner, no Swift toolchain, and no Xcode to install.

```yaml
- uses: hbmartin/github-action-spm_version_updates@v1
  with:
    xcode-project-path: 'MyApp.xcodeproj'   # or: package-manifest-paths
```

The same dependency checker can be used **three ways**, so it slots into whatever CI you already run:

- **Standalone GitHub Action** — drop the `uses:` step above into a workflow on `ubuntu-latest`. This is the quickest start; see the [Quick Start](#quick-start).
- **Danger plugin** — run the checks inside an existing [Danger](https://danger.systems/ruby/) step via the [`danger-spm_version_updates`](https://rubygems.org/gems/danger-spm_version_updates) gem; see [Danger plugin](#danger-plugin).
- **Ruby gem** — call the core [`spm_version_updates`](https://rubygems.org/gems/spm_version_updates) gem directly from any Ruby script, such as a Fastlane lane.

Whichever you choose, dependencies can be read from an `.xcodeproj`, one or more `Package.swift` manifests, or `Package.resolved` files on their own — see [Source modes](#source-modes) for picking between them.

📖 **SwiftPM-first repo?** If your dependencies live in `Package.swift` manifests rather than in the `.xcodeproj`, see the [Swift manifest mode guide](docs/swiftpm-manifest-mode.md) for setup and migration steps.

## Contents

- [Why this action?](#why-this-action)
- [Features](#features)
- [Quick Start](#quick-start)
- [Permissions](#permissions)
- [Security](#security)
- [Source modes](#source-modes)
- [Configuration Options](#configuration-options)
- [How dependency constraints are handled](#how-dependency-constraints-are-handled)
- [Outputs](#outputs)
- [Example output](#example-output)
- [Applying updates automatically](#applying-updates-automatically)
- [Advanced configuration](#advanced-configuration)
- [Danger plugin](#danger-plugin)
- [Limitations](#limitations)
- [Troubleshooting](#troubleshooting)
- [Versioning](#versioning)
- [Development](#development)
- [Authors](#authors)
- [License](#license)

## Why this action?

Swift dependency updates are awkward to keep an eye on in CI. Here's how this action compares to the common alternatives:

| | This action | Dependabot | Renovate |
| --- | --- | --- | --- |
| Multiple `Package.swift` (SwiftPM-first layout) | ✅ any number of manifests | ❌ `.xcodeproj`/workspace only | ✅ |
| Swift/Xcode toolchain or macOS runner | ❌ not needed | n/a | ❌ not needed |
| Where it runs | `ubuntu-latest`, seconds | hosted | hosted / self-hosted |
| Default output | one self-updating PR comment | one PR per dependency | PRs (groupable) |
| Report-only (no auto-PRs) | ✅ | ❌ | optional |
| Noise control (pre-releases, pins, per-repo rules) | ✅ fine-grained | limited | ✅ |

In short:

- **It handles SwiftPM-first repos.** Dependabot only reads packages declared in an `.xcodeproj`/workspace; this action checks **either** an `.xcodeproj` **or** any number of `Package.swift` manifests.
- **No toolchain, no macOS minutes.** It never resolves a graph or runs `swift package`; it parses your manifests/`Package.resolved` and queries each dependency's tags with `git ls-remote`, so it runs on cheap `ubuntu-latest` runners in seconds.
- **Report-only and non-intrusive.** Instead of opening a pull request per dependency, it posts and continuously updates a **single** PR comment — so your PR list stays clean and you decide when to bump.
- **You control the noise.** Pre-releases, branch/revision pins, exact pins, and above-maximum releases are all opt-in/opt-out, and you can ignore specific repositories entirely.

## Features

- ✅ **Three source modes** — point it at an `.xcodeproj`, at your `Package.swift` manifests, or directly at `Package.resolved` files
- 📦 **Comprehensive Detection** — supports all SPM dependency constraint types
- 🧩 **Multiple manifests** — check several `Package.swift` files (e.g. app modules + build tools) in one run
- 💬 **Smart PR Comments** — creates and updates a single informative pull request comment
- 📝 **Release notes** — enriches update comments with GitHub release notes by default
- 🛠️ **Optional apply mode** — rewrites supported `Package.swift` requirements in the workspace for companion PR workflows
- 🔧 **Highly Configurable** — control exactly what updates to report
- 🏃 **Runs on `ubuntu-latest`** — no macOS runner, no Swift toolchain, no Xcode required
- 📋 **Package.resolved Support** — works with both v1 and v2 formats

## Quick Start

### Xcode project mode

```yaml
name: Check SPM Dependencies
on:
  pull_request:
    paths:
      - '**/*.xcodeproj/**'
      - '**/Package.resolved'

jobs:
  spm-updates:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
      - uses: hbmartin/github-action-spm_version_updates@v1
        with:
          xcode-project-path: 'MyApp.xcodeproj'
```

### Swift manifest mode

```yaml
name: Swift Package Version Updates
on:
  pull_request:
    paths:
      - 'Modules/Package.swift'
      - 'Modules/Package.resolved'
      - 'BuildTools/Package.swift'
      - 'BuildTools/Package.resolved'

permissions:
  contents: read
  pull-requests: write

jobs:
  spm-version-updates:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hbmartin/github-action-spm_version_updates@v1
        with:
          package-manifest-paths: |
            Modules/Package.swift
            BuildTools/Package.swift
          report-above-maximum: true
```

No temporary Xcode project, no synthetic `Package.resolved`, no repo-specific parser.

📚 **More complete workflows** — scheduled reports as tracking issues, fork-safe runs, merge gating, and automatic bump PRs built on `updates-json` — are assembled in the [cookbook](docs/cookbook.md).

## Permissions

The action reads your manifests from the checked-out repo and posts a single comment on the pull request, so the job needs:

```yaml
permissions:
  contents: read         # checkout / read the manifests
  pull-requests: write   # create and update the summary comment
  issues: write          # only with open-tracking-issue: true
```

A few things worth knowing about the token:

- **`github-token` defaults to `${{ github.token }}`**, the automatic per-job token. You only need to set it explicitly to use a PAT or a GitHub App token (for example, to raise the API rate limit or to comment on a repository the default token can't write to).
- **The token is used to post the comment, not to look up versions.** Dependency tags are fetched with `git ls-remote`, so a low rate limit on the token won't slow checks down.

Running on pull requests **from forks** needs extra care — see [Security](#security).

## Security

This action reads dependency URLs from your manifests and contacts each one with `git ls-remote`. On your own branches that's routine, but pull requests from forks can rewrite those URLs, so treat fork runs as untrusted: check out the PR head with `persist-credentials: false`, keep extra secrets out of the job, and restrict version lookups to known hosts with `allow-hosts`. Transports are limited to `https`, `ssh`, and `git`; `file`, `ext`, and remote helpers are blocked.

See the [security guide](docs/security.md) for the full threat model, the `allow-hosts` matching semantics, and a hardened `pull_request_target` example.

## Source modes

Provide one source: `xcode-project-path`, `package-manifest-paths`, or `package-resolved-paths` by itself. `package-resolved-paths` may also be used with manifest mode to override the inferred resolved files.

### Xcode project mode (`xcode-project-path`)

- Parses the `.xcodeproj` directly and extracts its `XCRemoteSwiftPackageReference` objects.
- Runs without Xcode, Swift, or a macOS runner; the project file is read by Ruby.
- Locates `Package.resolved` in the Xcode-adjacent workspace locations:
  - `<Project>.xcworkspace/xcshareddata/swiftpm/Package.resolved`
  - `<Project>.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- Logs a warning if `Package.resolved` has pins but the `.xcodeproj` has no remote package references, which usually means the project should use Swift manifest mode instead.

Use this when the `.xcodeproj` directly owns its remote package references.

### Swift manifest mode (`package-manifest-paths`)

- Parses one or more `Package.swift` manifests and extracts their direct `.package(...)` dependencies.
- Reads the matching `Package.resolved` files and compares declared dependencies against resolved pins.
- For each manifest, the resolved file is inferred to sit next to it (e.g. `Modules/Package.swift` → `Modules/Package.resolved`). Override this with `package-resolved-paths`.
- Every expected `Package.resolved` must exist — the action fails (rather than silently reporting incomplete results) if one is missing, naming the file so you can commit it or point `package-resolved-paths` elsewhere.
- Set `allow-missing-resolved: true` to degrade missing resolved files into warnings and continue checking the manifests that still have pins.
- Resolved pins from every file are merged by normalized repository URL, and each warning is annotated with the manifest it came from.
- Closed Swift ranges (`"1.0.0"..."2.0.0"`) are normalized the same way SwiftPM does — to the half-open range `"1.0.0"..<"2.0.1"` — so the inclusive upper bound is preserved.

Manifest parsing is done with a lightweight, dependency-free scanner. The common declaration forms are supported:

```swift
.package(url: "https://github.com/foo/bar", from: "1.2.3")
.package(url: "https://github.com/foo/bar", exact: "1.2.3")
.package(url: "https://github.com/foo/bar", branch: "main")
.package(url: "https://github.com/foo/bar", revision: "abcdef")
.package(url: "https://github.com/foo/bar", "1.0.0"..<"2.0.0")
.package(url: "https://github.com/foo/bar", .upToNextMajor(from: "1.2.3"))
.package(url: "https://github.com/foo/bar", .upToNextMinor(from: "1.2.3"))
.package(url: "https://github.com/foo/bar", .exact("1.2.3"))
```

Local packages (`.package(path: ...)`) and commented-out declarations are ignored.

### Package.resolved-only mode (`package-resolved-paths`)

- Activated when `package-resolved-paths` is provided without `xcode-project-path` or `package-manifest-paths`.
- Reads pins directly from the resolved files and checks version pins against available tags.
- Revision-only pins are still quiet unless `check-revisions: true`.
- Update records use `requirement_kind: "resolvedPin"` and include a `swift package update <identity>` suggestion, but there is no `Package.swift` requirement text to rewrite.

Use this for lockfile audits, generated projects, or repositories where you want a report from committed pins without parsing manifests.

## Configuration Options

Exactly one source mode is required (see [Source modes](#source-modes)); every other input is optional.

<!-- inputs-table:begin (generated from action.yml by `rake docs:tables`; edit descriptions there) -->
| Input | Description | Default |
| ----- | ----------- | ------- |
| `xcode-project-path` | Xcode mode: path to the .xcodeproj file. Mutually exclusive with package-manifest-paths and package-resolved-paths-only mode. |  |
| `package-manifest-paths` | Manifest mode: newline-separated Package.swift paths. Mutually exclusive with xcode-project-path. |  |
| `package-resolved-paths` | Newline-separated Package.resolved paths. With package-manifest-paths, overrides default adjacent resolved files; alone, activates Package.resolved-only mode. |  |
| `check-when-exact` | Include exact version constraints when checking for updates | `false` |
| `check-branches` | Check branch-pinned dependencies for newer commits | `true` |
| `check-revisions` | Report the latest tagged release for revision-pinned dependencies | `false` |
| `report-above-maximum` | Also report versions above the maximum allowed constraint range | `false` |
| `report-pre-releases` | Include pre-release versions when choosing available updates | `false` |
| `ignore-repos` | Comma-separated repository URLs to skip before any git lookup |  |
| `repo-rules-path` | Path to a YAML file with per-repository semantic update suppression rules |  |
| `allow-hosts` | Comma-separated git remote hostnames allowed for version lookups. Empty allows any host for allowed git protocols. |  |
| `version-lookup-workers` | Maximum concurrent git tag lookups. Must be a positive integer. | `4` |
| `allow-missing-resolved` | When true, missing Package.resolved files are reported as warnings instead of failing the run. | `false` |
| `apply-updates` | Rewrite supported Package.swift version requirements in the workspace. Manifest mode only; pair with a pull-request creation step. | `false` |
| `enrich-release-notes` | Fetch GitHub release notes for updated packages and include them in PR comments or tracking issues. | `true` |
| `fail-on` | Fail when updates are found: true/any for any update, major/minor/patch for semantic updates at or above that severity, or empty/false/none to never fail. |  |
| `comment` | Post or update the pull request comment. Set false to disable all PR commenting; outputs, the step summary, and annotations are still produced, and a comment left by a prior run is kept as-is rather than deleted. Tracking issues (open-tracking-issue) are unaffected. | `true` |
| `comment-on-success` | Post an up-to-date pull request comment on clean runs. By default, clean runs delete the prior generated comment instead. | `false` |
| `open-tracking-issue` | On runs without a pull request context (schedule, workflow_dispatch, push), open or update a single tracking issue with the update report, and close it when everything is up to date. Requires issues: write permission. | `false` |
| `cache-version-tags` | Cache git tag lookup results with actions/cache to make repeated runs faster | `true` |
| `version-tags-cache-ttl` | Freshness window, in seconds, for persisted git tag lookups. Must be a non-negative integer; set 0 to disable persistent cache reads and writes. | `21600` |
| `setup-ruby` | Set up Ruby and install this action bundle. Set false only for later invocations in the same job after an earlier invocation has already run setup. | `true` |
| `github-token` | Token used to create or update pull request comments. Defaults to github.token. | `${{ github.token }}` |
<!-- inputs-table:end -->

### Runtime setup

By default, each invocation sets up Ruby and installs the action bundle from this
action's directory. When `xcode-project-path` is empty, the bundle skips the
Xcode project parser dependency, so manifest and resolved-only runs avoid
installing `xcodeproj`.

If a job invokes this action multiple times, leave `setup-ruby` enabled on the
first invocation and set `setup-ruby: false` on later invocations that use the
same source mode or a subset of the first invocation's runtime dependencies. The
action checks for Ruby, Bundler, and installed gems before running so a skipped
setup fails with a clear error instead of a Bundler backtrace.

## How dependency constraints are handled

| Constraint | Manifest form | Behavior |
| ---------- | ------------- | -------- |
| Up to next major | `from:` / `.upToNextMajor(from:)` | Reports newer versions within the same major version. |
| Up to next minor | `.upToNextMinor(from:)` | Reports newer versions within the same minor version. |
| Version range | `"1.0.0"..<"2.0.0"` | Reports newer versions below the maximum. |
| Exact | `exact:` / `.exact(...)` | Skipped unless `check-when-exact: true`. |
| Branch | `branch:` / `.branch(...)` | Reports newer commits on the branch unless `check-branches: false`. |
| Revision | `revision:` / `.revision(...)` | Skipped unless `check-revisions: true`. A pinned commit has no general "newer" version, so when enabled the action only reports the latest tagged release for reference. |

When `report-above-maximum: true`, the action additionally reports the newest version that exists above the configured maximum (e.g. a new major release that your constraint would not pick up).

### Pre-releases

Across all of the constraint types above, pre-release tags (versions with a `-` suffix such as `2.0.0-rc.1` or `600.0.0-prerelease-2024-09-04`) are **ignored by default** — only stable releases are reported. Set `report-pre-releases: true` to make pre-releases eligible, in which case the newest matching version is reported even if it is a pre-release.

## Outputs

The action always writes machine-readable outputs, appends a GitHub step summary, and emits `::warning` annotations for each update. Pull request runs get a summary comment when updates are found. Clean runs delete the prior generated comment by default; set `comment-on-success: true` to keep an up-to-date comment instead, or `comment: false` to disable PR commenting entirely. Scheduled and `workflow_dispatch` runs still have visible results in the workflow run summary and annotations — set `open-tracking-issue: true` to also keep a single tracking issue updated with the same report (it is closed automatically once everything is up to date).

<!-- outputs-table:begin (generated from action.yml by `rake docs:tables`; edit descriptions there) -->
| Output | Description |
| ------ | ----------- |
| `updates-found` | Number of dependency updates found |
| `major-updates-found` | Number of major semantic-version updates found |
| `minor-updates-found` | Number of minor semantic-version updates found |
| `patch-updates-found` | Number of patch semantic-version updates found |
| `parse-warnings` | Number of .package(...) declarations that could not be parsed and were skipped. Not counted in updates-found and never fails the run, but skipped declarations are listed in the step summary and PR comment with a link to open an issue — a PR comment is posted even when no updates were found so skips are never silent. |
| `missing-resolved` | Number of missing Package.resolved files reported when allow-missing-resolved is true |
| `applied-updates` | Number of Package.swift requirement updates applied when apply-updates is true |
| `applied-updates-json` | JSON array of applied Package.swift update records. Empty array when apply-updates is false or nothing was applied. |
| `updates-json` | JSON array of update objects. Each object has a message field and, when available, structured fields such as type, package, repository_url, current_version, available_version, severity, note, source, requirement_kind, package_identity, suggested_command, and suggested_requirement. |
| `blocked` | Whether the run was blocked before version lookup by a security gate such as allow-hosts |
| `error-message` | Failure message when blocked is true |
| `tracking-issue-number` | Number of the tracking issue created or updated, when open-tracking-issue is enabled and the run had no pull request context. Empty otherwise. |
| `tracking-issue-url` | HTML URL of the tracking issue created or updated. Empty otherwise. |
<!-- outputs-table:end -->

### `updates-json` example

```json
[
  {
    "type": "version",
    "package": "onevcat/Kingfisher",
    "repository_url": "https://github.com/onevcat/Kingfisher",
    "current_version": "7.12.0",
    "available_version": "8.0.0",
    "severity": "major",
    "message": "Newer version of onevcat/Kingfisher: 8.0.0",
    "source": "Modules/Package.swift",
    "requirement_kind": "upToNextMajorVersion",
    "package_identity": "kingfisher",
    "suggested_command": "swift package update kingfisher"
  },
  {
    "type": "version",
    "package": "SwiftGen/SwiftGenPlugin",
    "repository_url": "https://github.com/SwiftGen/SwiftGenPlugin",
    "current_version": "6.6.2",
    "available_version": "6.7.0",
    "severity": "minor",
    "message": "Newer version of SwiftGen/SwiftGenPlugin: 6.7.0",
    "source": "BuildTools/Package.swift",
    "requirement_kind": "upToNextMajorVersion",
    "package_identity": "swiftgenplugin",
    "suggested_command": "swift package update swiftgenplugin"
  }
]
```

`severity` is present only for semantic `version` / `above_maximum` updates, `source` only in Swift manifest and Package.resolved-only modes, and `note` only for branch/revision/above-maximum/resolved-pin reports. `repository_url` is redacted if it contained embedded credentials. When no updates are found, the output is `[]`.

Each update also carries upgrade guidance: `package_identity` is the SwiftPM package identity (derived from the repository URL), `suggested_command` is a ready-to-run `swift package update <identity>` command (manifest mode only — it never appears in Xcode project mode, where updates go through Xcode), and `suggested_requirement` is the new `Package.swift` requirement text needed first when the suggested version is outside the declared constraint (for example `from: "8.0.0"` on an `above_maximum` report, or `exact: "8.0.0"` for exact pins). The same guidance is rendered in the PR comment's "How to update dependencies" section and in the step summary.

When `allow-missing-resolved: true`, `missing-resolved` counts missing resolved files that were reported instead of failing the run. When `apply-updates: true`, `applied-updates` and `applied-updates-json` describe the `Package.swift` requirement rewrites made in the workspace.

Use `fail-on: major` when only major semantic-version updates should fail the job after the outputs, step summary, annotations, and PR comment have been written. Use `minor` to fail on major or minor updates, `patch` to fail on any semantic-version update, and `true` or `any` to fail on every reported update, including branch or revision reports.

```yaml
- id: spm-updates
  uses: hbmartin/github-action-spm_version_updates@v1
  with:
    package-manifest-paths: Modules/Package.swift
    fail-on: major

- name: Use update count
  if: ${{ always() && steps.spm-updates.outputs.updates-found != '0' }}
  run: echo '${{ steps.spm-updates.outputs.updates-json }}'
```

### Per-repository rules

Use `ignore-repos` when a dependency should be skipped entirely before any git lookup. Use `repo-rules-path` to point at a YAML file of per-repository rules when the dependency should still be checked, but selected semantic-version reports should be hidden from comments, annotations, outputs, and `fail-on` counts:

```yaml
repositories:
  - url: "https://github.com/example/noise"
    ignore-until: "2.0.0"      # hide reports below 2.0.0; 2.0.0 itself reports

  - url: "https://github.com/example/no-major"
    allowed-updates: "minor"   # hide major reports; patch and minor still report
```

See the [repository rules reference](docs/repo-rules.md) for the full schema, the URL matching semantics, and worked examples.

## Example output

When the action finds available updates, it posts (and keeps updating) a single comment on your pull request:

> ## 📦 SPM Version Updates
>
> ⚠️ **Found 2 packages with potential dependency updates:**
>
> | Package | Current → Available | Source | Links |
> | --- | --- | --- | --- |
> | `onevcat/Kingfisher` | `7.12.0` → `8.0.0` | `Modules/Package.swift` | [Compare](https://github.com/onevcat/Kingfisher/compare/7.12.0...8.0.0)<br>[Releases](https://github.com/onevcat/Kingfisher/releases) |
> | `SwiftGen/SwiftGenPlugin` | `6.6.2` → `6.7.0` | `BuildTools/Package.swift` | [Compare](https://github.com/SwiftGen/SwiftGenPlugin/compare/6.6.2...6.7.0)<br>[Releases](https://github.com/SwiftGen/SwiftGenPlugin/releases) |
>
> <details><summary>💡 How to update dependencies</summary>
> Ready-to-run <code>swift package update</code> commands per manifest directory, plus any manifest requirement changes needed first.
> </details>

The `Source` column is filled in Swift manifest mode, where it tells you which manifest a given update applies to (Xcode mode shows "Xcode project"). Compare/Releases links are rendered for GitHub, GitLab, and Bitbucket remotes.

## Applying updates automatically

`apply-updates: true` rewrites supported `Package.swift` version requirements in the checked-out workspace. It does not open a pull request itself; pair it with a normal PR creation action:

```yaml
permissions:
  contents: write
  pull-requests: write

steps:
  - uses: actions/checkout@v4
  - id: spm
    uses: hbmartin/github-action-spm_version_updates@v1
    with:
      package-manifest-paths: Package.swift
      apply-updates: 'true'
      fail-on: ''
  - uses: peter-evans/create-pull-request@v7
    with:
      branch: spm-version-updates
      title: Update Swift package requirements
      commit-message: Update Swift package requirements
```

Apply mode is manifest-only in this version. Xcode project files are not rewritten, and Package.resolved-only mode has no manifest requirement to edit. If a rewrite fails after some files have already changed, the action writes outputs and the step summary for the successful rewrites, emits an error annotation for the failed manifest, and exits non-zero so the partial workspace diff is visible.

## Advanced configuration

```yaml
- uses: hbmartin/github-action-spm_version_updates@v1
  with:
    package-manifest-paths: |
      Modules/Package.swift
      BuildTools/Package.swift
    package-resolved-paths: |
      Modules/Package.resolved
      BuildTools/Package.resolved
    check-when-exact: true
    check-branches: true
    check-revisions: false
    report-above-maximum: true
    ignore-repos: 'https://github.com/pointfreeco/swift-snapshot-testing'
    repo-rules-path: '.github/spm-version-rules.yml'
    allow-hosts: 'github.com,gitlab.com'
    version-lookup-workers: 4
    allow-missing-resolved: false
    enrich-release-notes: true
    version-tags-cache-ttl: 21600
    fail-on: ''
```

## Danger plugin

The same checker also ships as a [Danger](https://danger.systems/ruby/) plugin, [`danger-spm_version_updates`](https://rubygems.org/gems/danger-spm_version_updates), if you'd rather run dependency checks inside an existing Danger step than as a standalone action. The plugin supports both source modes — Xcode projects and `Package.swift` manifests — and requires Ruby >= 3.2.

Add it to your Gemfile:

```ruby
gem "danger-spm_version_updates"
```

Then call it from your `Dangerfile`:

```ruby
spm_version_updates.check_when_exact = false
spm_version_updates.report_above_maximum = false
spm_version_updates.report_pre_releases = false
spm_version_updates.ignore_repos = ["https://github.com/pointfreeco/swift-snapshot-testing"]
spm_version_updates.repo_rules_path = ".github/spm-version-rules.yml"
spm_version_updates.check_for_updates("MyApp.xcodeproj")
```

Or, for SwiftPM-first repos, check `Package.swift` manifests directly:

```ruby
spm_version_updates.check_manifests(["Modules/Package.swift", "BuildTools/Package.swift"])
```

`check_manifests` accepts a single path or a list, and an optional second argument with explicit `Package.resolved` paths (by default a `Package.resolved` next to each manifest is used). Each available update is reported as a Danger `warn` that includes Compare/Releases links for supported hosts, the originating manifest, and a ready-to-run `swift package update` command in manifest mode. The configurable accessors mirror the action inputs of the same name: `check_when_exact`, `check_branches`, `check_revisions`, `report_above_maximum`, `report_pre_releases`, `ignore_repos`, and `repo_rules_path`.

## Limitations

- **The built-in PR comment sink is GitHub-specific.** Comments flow through a small reporter sink interface, but the only included sink posts through the GitHub API, so the PR comment requires running inside GitHub Actions on a GitHub-hosted pull request. Outputs, step summaries, and annotations are still emitted on non-PR runs.
- **Version lookups need a reachable git host.** Tags and branches are read with `git ls-remote` over `https`, `ssh`, or `git`, so any host exposed through those transports works (GitHub, GitLab, Bitbucket, self-hosted).
  - Private dependencies are supported as long as the runner is already authenticated to fetch them (SSH key or credentials in the environment); the action does not manage those credentials for you.
  - After bounded retries, an unreachable or auth-failing dependency fails the action instead of being treated as "no updates."
  - For untrusted PRs or locked-down runners, set `allow-hosts`. Matching is exact, case-insensitive, and ignores schemes, credentials, paths, and ports; an off-list dependency fails the action and writes `blocked=true` plus `error-message`.
- **Updates are detected from semver tags.** A dependency that doesn't publish semver-style version tags won't produce version updates. Successful tag lookups are cached briefly across runs by default; branch- and revision-pinned dependencies are handled separately via `check-branches` / `check-revisions`.
- **Local packages are skipped.** `.package(path: ...)` dependencies and commented-out declarations are ignored.
- **Apply mode is manifest-only.** It rewrites supported `Package.swift` requirement literals and deliberately skips Xcode project rewriting to avoid project-file churn or corruption.
- **Release-note enrichment uses the GitHub API.** It is on by default, capped per run, and disabled for the rest of a run after non-404 API errors. Set `enrich-release-notes: false` to skip these calls.
- **Unparseable declarations are reported, not checked.** A `.package(...)` declaration whose version requirement the parser doesn't recognize (or that has unbalanced parentheses) is skipped, counted in the `parse-warnings` output, and listed in the step summary and PR comment with a link to open an issue here.

## Troubleshooting

The [troubleshooting guide](docs/troubleshooting.md) covers the common failure modes: no comment on the PR, no tracking issue on a scheduled run, a missing `Package.resolved`, "no updates found" when you know one exists, non-zero `parse-warnings`, `blocked=true`, unreachable private dependencies, and the "Provide exactly one of…" error.

## Versioning

Pin to a major version tag so you automatically receive backward-compatible updates:

```yaml
uses: hbmartin/github-action-spm_version_updates@v1
```

You can also pin to an exact release (e.g. `@v1.0.0`) or to a commit SHA for maximum reproducibility.

## Development

This repository hosts three layered components:

- [`gems/spm_version_updates`](gems/spm_version_updates) — the core version-checker gem (no Danger or GitHub API dependencies)
- [`gems/danger-spm_version_updates`](gems/danger-spm_version_updates) — the Danger plugin gem, a thin wrapper over the core
- [`action/`](action) + `action.yml` — this composite GitHub Action, which drives the core gem directly

Per-layer API documentation is published to
[GitHub Pages](https://hbmartin.github.io/github-action-spm_version_updates/)
on each release; see [docs/architecture.md](docs/architecture.md) for how the
layers fit together. Build the site locally with `bundle exec rake docs`
(output in `_site/`).

To work on the action locally:

1. Clone this repository
2. Make your changes to the Ruby files in `action/lib/` (or `gems/*/lib/` for checker logic)
3. Run the action specs: `bundle exec rspec spec/action spec/core`
4. Test against a sample project:

   ```bash
   GITHUB_WORKSPACE="$(pwd)" \
     INPUT_XCODE_PROJECT_PATH=path/to/project.xcodeproj \
     bundle exec ruby action/lib/action.rb
   ```

See [MAINTENANCE.md](MAINTENANCE.md) for the full development and release guide.

## Authors

- [Harold Martin](https://www.linkedin.com/in/harold-martin-98526971/) - harold.martin at gmail

## License

Released under the [MIT License](LICENSE.txt). Copyright (c) 2023-2026 Harold Martin.

Swift and the Swift logo are trademarks of Apple Inc.
