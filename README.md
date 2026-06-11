# Swift Package Version Updates GitHub Action

[![CI](https://github.com/hbmartin/github-action-spm_version_updates/actions/workflows/lint_and_test.yml/badge.svg)](https://github.com/hbmartin/github-action-spm_version_updates/actions/workflows/lint_and_test.yml)
[![CodeFactor](https://www.codefactor.io/repository/github/hbmartin/github-action-spm_version_updates/badge/main)](https://www.codefactor.io/repository/github/hbmartin/github-action-spm_version_updates/overview/main)
[![Release](https://img.shields.io/github/v/release/hbmartin/github-action-spm_version_updates?sort=semver&logo=github)](https://github.com/hbmartin/github-action-spm_version_updates/releases)
[![GitHub Marketplace](https://img.shields.io/badge/Marketplace-Swift%20Package%20Version%20Updates-blue?logo=githubactions&logoColor=white)](https://github.com/marketplace/actions/spm-version-updates)
[![Gem Version](https://img.shields.io/gem/v/danger-spm_version_updates?logo=rubygems&label=danger%20plugin)](https://rubygems.org/gems/danger-spm_version_updates)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A GitHub Action to automatically detect and report available updates for your Swift Package Manager (SPM) dependencies.

🚀 **Fast, lightweight, and works without Swift or Xcode installed on your CI runner** — it parses your manifests directly and checks each dependency with `git ls-remote`, so there's no macOS runner, no Swift toolchain, and no Xcode to install.

```yaml
- uses: hbmartin/github-action-spm_version_updates@v1
  with:
    xcode-project-path: 'MyApp.xcodeproj'   # or: package-manifest-paths
```

It works in two ways:

- **Xcode project mode** — dependencies declared as `XCRemoteSwiftPackageReference` objects inside an `.xcodeproj`.
- **Swift manifest mode** — dependencies declared in one or more `Package.swift` manifests (a SwiftPM-first / modular iOS layout).

> **Which mode do I use?** If your `project.pbxproj` contains `XCRemoteSwiftPackageReference` entries, use **Xcode project mode** (`xcode-project-path`). If your dependencies live in one or more `Package.swift` files, use **Swift manifest mode** (`package-manifest-paths`). Provide exactly one.

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

- ✅ **Two source modes** — point it at an `.xcodeproj` **or** at your `Package.swift` manifests
- 📦 **Comprehensive Detection** — supports all SPM dependency constraint types
- 🧩 **Multiple manifests** — check several `Package.swift` files (e.g. app modules + build tools) in one run
- 💬 **Smart PR Comments** — creates and updates a single informative pull request comment
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

## Permissions

The action reads your manifests from the checked-out repo and posts a single comment on the pull request, so the job needs:

```yaml
permissions:
  contents: read         # checkout / read the manifests
  pull-requests: write   # create and update the summary comment
```

A few things worth knowing about the token:

- **`github-token` defaults to `${{ github.token }}`**, the automatic per-job token. You only need to set it explicitly to use a PAT or a GitHub App token (for example, to raise the API rate limit or to comment on a repository the default token can't write to).
- **The token is used to post the comment, not to look up versions.** Dependency tags are fetched with `git ls-remote`, so a low rate limit on the token won't slow checks down.

Running on pull requests **from forks** needs extra care — see [Security](#security).

## Security

This action reads dependency URLs from your manifests and contacts each one with `git ls-remote`. On your own branches that's routine, but pull requests from forks can rewrite those URLs, so treat fork runs as untrusted.

- **Fork PRs get a read-only `GITHUB_TOKEN`**, so the comment step can't write. To run on fork PRs, trigger with `pull_request_target` (review the [security implications](https://securitylab.github.com/resources/github-actions-preventing-pwn-requests/)) or post the results from a separate, trusted workflow.
- **Fork PR manifests are untrusted input.** With `pull_request_target`, checking out the PR head lets a fork change `Package.swift` or `.xcodeproj` dependency URLs. Because lookups use `git ls-remote`, a malicious PR could point the runner at hosts it can reach and at credentials already available to git.
- **Transports are restricted.** Lookups are limited to Git's `https`, `ssh`, and `git` transports; `file`, `ext`, and remote-helper transports are blocked.
- **Lock down fork runs.** Set `persist-credentials: false`, avoid extra secrets / SSH keys / private network access, and restrict version lookups with `allow-hosts`. Host matching is exact, case-insensitive, and ignores schemes, credentials, paths, and ports; an off-list dependency fails the action and writes `blocked=true` plus `error-message`.

```yaml
on:
  pull_request_target:

permissions:
  contents: read
  pull-requests: write

jobs:
  spm-version-updates:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.sha }}
          persist-credentials: false
      - uses: hbmartin/github-action-spm_version_updates@v1
        with:
          package-manifest-paths: Modules/Package.swift
          allow-hosts: github.com
```

## Source modes

You must provide **exactly one** of `xcode-project-path` or `package-manifest-paths`. Providing both (or neither) fails with a clear error.

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

## Configuration Options

| Input | Description | Required | Default |
| ----- | ----------- | -------- | ------- |
| `xcode-project-path` | Path to your Xcode project file (`.xcodeproj`). Provide this **or** `package-manifest-paths`. | One of the two | |
| `package-manifest-paths` | Newline-separated list of `Package.swift` paths. Provide this **or** `xcode-project-path`. | One of the two | |
| `package-resolved-paths` | Optional newline-separated list of `Package.resolved` paths. Defaults to a `Package.resolved` next to each manifest. | No | inferred |
| `check-when-exact` | Check for updates even when using `exact` version constraints | No | `false` |
| `check-branches` | Check for newer commits on branch-pinned dependencies | No | `true` |
| `check-revisions` | Report the latest tagged version for revision-pinned dependencies | No | `false` |
| `report-above-maximum` | Report versions above the maximum constraint range | No | `false` |
| `report-pre-releases` | Include pre-release versions in update reports | No | `false` |
| `ignore-repos` | Comma-separated list of repository URLs to ignore | No | `''` |
| `repo-rules-path` | Path to a YAML file with per-repository semantic update suppression rules | No | `''` |
| `allow-hosts` | Comma-separated list of git remote hostnames allowed for enabled version lookups. Empty allows any host for the allowed git protocols. | No | `''` |
| `fail-on-updates` | Legacy fail behavior. Set `true` to fail on any update, or `major` / `minor` / `patch` to fail on semantic version updates at or above that severity. | No | `false` |
| `fail-on` | Fail on semantic version updates at or above this severity: `major`, `minor`, or `patch`. Overrides `fail-on-updates` when set. | No | `''` |
| `comment` | Post or update the pull request comment. Set `false` to disable all PR commenting; outputs, the step summary, and annotations are still produced. | No | `true` |
| `comment-on-success` | Post an up-to-date pull request comment on clean runs. By default, clean runs delete the prior generated comment instead. | No | `false` |
| `cache-version-tags` | Persist successful git tag lookups between runs with `actions/cache`. | No | `true` |
| `version-tags-cache-ttl` | Freshness window, in seconds, for persisted git tag lookups. Set `0` to disable persistent cache reads and writes. | No | `21600` |
| `setup-ruby` | Set up Ruby and install this action's bundle. Set to `false` only for later invocations in the same job after an earlier invocation has already run setup. | No | `true` |
| `github-token` | Token used to create or update pull request comments. | No | `${{ github.token }}` |

### Runtime setup

By default, each invocation sets up Ruby and installs the action bundle from this
action's directory. In Swift manifest mode, the bundle skips the Xcode project
parser dependency, so manifest-only runs avoid installing `xcodeproj`.

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

The action always writes machine-readable outputs, appends a GitHub step summary, and emits `::warning` annotations for each update. Pull request runs get a summary comment when updates are found. Clean runs delete the prior generated comment by default; set `comment-on-success: true` to keep an up-to-date comment instead, or `comment: false` to disable PR commenting entirely. Scheduled and `workflow_dispatch` runs still have visible results in the workflow run summary and annotations.

| Output | Description |
| ------ | ----------- |
| `updates-found` | Number of dependency updates found. |
| `major-updates-found` | Number of major semantic-version updates found. |
| `minor-updates-found` | Number of minor semantic-version updates found. |
| `patch-updates-found` | Number of patch semantic-version updates found. |
| `updates-json` | JSON array of update objects. Each object has a `message` field and, when available, structured fields such as `type`, `package`, `repository_url`, `current_version`, `available_version`, `severity`, `note`, and `source`. |
| `blocked` | `true` when the action stopped before a version lookup because a security gate such as `allow-hosts` blocked it; otherwise `false`. |
| `error-message` | Failure message when `blocked` is `true`. |

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
    "source": "Modules/Package.swift"
  },
  {
    "type": "version",
    "package": "SwiftGen/SwiftGenPlugin",
    "repository_url": "https://github.com/SwiftGen/SwiftGenPlugin",
    "current_version": "6.6.2",
    "available_version": "6.7.0",
    "severity": "minor",
    "message": "Newer version of SwiftGen/SwiftGenPlugin: 6.7.0",
    "source": "BuildTools/Package.swift"
  }
]
```

`severity` is present only for semantic `version` / `above_maximum` updates, `source` only in Swift manifest mode, and `note` only for branch/revision/above-maximum reports. `repository_url` is redacted if it contained embedded credentials. When no updates are found, the output is `[]`.

Use `fail-on: major` when only major semantic-version updates should fail the job after the outputs, step summary, annotations, and PR comment have been written. Use `minor` to fail on major or minor updates, and `patch` to fail on any semantic-version update. `fail-on-updates: true` remains supported when any reported update, including branch or revision updates, should fail the job.

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

Use `ignore-repos` when a dependency should be skipped entirely before any git lookup. Use `repo-rules-path` when the dependency should still be checked, but selected semantic-version reports should be hidden from comments, annotations, outputs, and `fail-on` counts.

```yaml
- uses: hbmartin/github-action-spm_version_updates@v1
  with:
    package-manifest-paths: Modules/Package.swift
    report-above-maximum: true
    repo-rules-path: .github/spm-version-rules.yml
```

```yaml
repositories:
  - url: "https://github.com/example/noise"
    ignore-until: "2.0.0"

  - url: "https://github.com/example/no-major"
    allowed-updates: "minor"
```

`ignore-until` suppresses semantic reports whose available version is below the configured version; version X itself still reports. `allowed-updates` accepts `patch`, `minor`, or `major`, where `minor` allows patch and minor reports but suppresses major reports. These rules apply only to semantic `version` and `above_maximum` reports; branch and revision reports keep using `check-branches`, `check-revisions`, and `ignore-repos`.

## Example output

When the action finds available updates, it posts (and keeps updating) a single comment on your pull request:

> ## 📦 SPM Version Updates
>
> ⚠️ **Found 2 potential dependency updates:**
>
> 1. Newer version of onevcat/Kingfisher: 8.0.0
>    Source: Modules/Package.swift
> 2. Newer version of SwiftGen/SwiftGenPlugin: 6.7.0
>    Source: BuildTools/Package.swift

The `Source:` line is only included in Swift manifest mode, where it tells you which manifest a given update applies to.

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
    version-tags-cache-ttl: 21600
    fail-on-updates: false
```

## Danger plugin

The same checker also ships as a [Danger](https://danger.systems/ruby/) plugin, [`danger-spm_version_updates`](https://rubygems.org/gems/danger-spm_version_updates), if you'd rather run dependency checks inside an existing Danger step than as a standalone action. The plugin operates in **Xcode project mode** only and requires Ruby >= 3.2.

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

Each available update is reported as a Danger `warn`. The configurable accessors mirror the action inputs of the same name: `check_when_exact`, `report_above_maximum`, `report_pre_releases`, `ignore_repos`, and `repo_rules_path`.

## Limitations

- **The built-in PR comment sink is GitHub-specific.** Comments flow through a small reporter sink interface, but the only included sink posts through the GitHub API, so the PR comment requires running inside GitHub Actions on a GitHub-hosted pull request. Outputs, step summaries, and annotations are still emitted on non-PR runs.
- **Version lookups need a reachable git host.** Tags and branches are read with `git ls-remote` over `https`, `ssh`, or `git`, so any host exposed through those transports works (GitHub, GitLab, Bitbucket, self-hosted).
  - Private dependencies are supported as long as the runner is already authenticated to fetch them (SSH key or credentials in the environment); the action does not manage those credentials for you.
  - After bounded retries, an unreachable or auth-failing dependency fails the action instead of being treated as "no updates."
  - For untrusted PRs or locked-down runners, set `allow-hosts`. Matching is exact, case-insensitive, and ignores schemes, credentials, paths, and ports; an off-list dependency fails the action and writes `blocked=true` plus `error-message`.
- **Updates are detected from semver tags.** A dependency that doesn't publish semver-style version tags won't produce version updates. Successful tag lookups are cached briefly across runs by default; branch- and revision-pinned dependencies are handled separately via `check-branches` / `check-revisions`.
- **Local packages are skipped.** `.package(path: ...)` dependencies and commented-out declarations are ignored.

## Troubleshooting

**No comment appeared on my PR.** Check that the job has `pull-requests: write` and that the run is a real pull request — fork PRs get a read-only token and can't comment (see [Security](#security)). On clean runs the prior comment is deleted by default; set `comment-on-success: true` to keep an "up to date" comment instead.

**The action failed with a missing `Package.resolved`.** In Swift manifest mode every manifest needs a resolved file next to it (e.g. `Modules/Package.swift` → `Modules/Package.resolved`). Commit the resolved file, or point `package-resolved-paths` at its real location.

**No updates found, but I know a newer version exists.** Updates are detected from semver-style tags. Pre-releases (unless `report-pre-releases: true`), versions above your constraint (unless `report-above-maximum: true`), and exact/revision pins (unless `check-when-exact` / `check-revisions`) are skipped by design. A dependency that doesn't publish version tags produces no updates, and `ignore-repos` / `repo-rules-path` may be suppressing the report.

**The output says `blocked=true`.** A dependency's host isn't in `allow-hosts`. Add the host (matching is exact and case-insensitive) or adjust your manifests; `error-message` names what was blocked.

**It can't reach a private dependency.** The runner must already be authenticated (SSH key or git credentials) to fetch private repos — the action doesn't manage credentials. Unreachable or auth-failing dependencies fail the run after retries rather than reporting "no updates."

**"Provide exactly one of…" error.** Set either `xcode-project-path` **or** `package-manifest-paths` — not both, and not neither.

## Versioning

Pin to a major version tag so you automatically receive backward-compatible updates:

```yaml
uses: hbmartin/github-action-spm_version_updates@v1
```

You can also pin to an exact release (e.g. `@v1.0.0`) or to a commit SHA for maximum reproducibility.

## Development

To work on this action locally:

1. Clone this repository
2. Make your changes to the Ruby files in `lib/`
3. Run the action specs: `bundle exec ruby -e "require 'rspec/core'; exit RSpec::Core::Runner.run(['spec/action'])"`
4. Test against a sample project:

   ```bash
   GITHUB_WORKSPACE="$(pwd)" \
     INPUT_XCODE_PROJECT_PATH=path/to/project.xcodeproj \
     bundle exec ruby lib/action.rb
   ```

## Authors

- [Harold Martin](https://www.linkedin.com/in/harold-martin-98526971/) - harold.martin at gmail

## License

Released under the [MIT License](LICENSE.txt). Copyright (c) 2023-2026 Harold Martin.

Swift and the Swift logo are trademarks of Apple Inc.
