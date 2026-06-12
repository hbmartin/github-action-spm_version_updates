# Architecture

This repository ships one tool through two front ends, built on a shared core.
It is organized as three layers, published as two gems plus a composite GitHub
Action:

```text
                ┌─────────────────────────────┐
                │  GitHub Action (action/)    │
                │  action.yml + action/lib    │
                └──────────────┬──────────────┘
                               │ depends on
┌──────────────────────────┐   ▼
│  Danger plugin gem       │  ┌──────────────────────────────┐
│  danger-spm_version_     │─▶│  Core gem                    │
│  updates (gems/danger-…) │  │  spm_version_updates         │
└──────────────────────────┘  │  (gems/spm_version_updates)  │
                              └──────────────────────────────┘
```

## Core gem: `spm_version_updates`

Location: `gems/spm_version_updates/`. Published to RubyGems as
[`spm_version_updates`](https://rubygems.org/gems/spm_version_updates).

Pure dependency-checking logic with no Danger, Octokit, or GitHub Actions
dependencies. CI enforces this layering: the core specs run in an isolated
bundle that must load without any action or plugin gems present.

Key components:

| Component | Responsibility |
| --- | --- |
| `SpmChecker` | Orchestrates a check run: reads packages, applies rules, fetches tags, classifies updates. |
| `ManifestParser` | Parses `.package(...)` declarations from `Package.swift` manifests. |
| `XcodeParser` / `XcodeProjectPackageReader` | Reads `XCRemoteSwiftPackageReference` dependencies from an `.xcodeproj` (loads `xcodeproj` lazily; it is optional). |
| `PackageResolved` | Reads pinned versions from `Package.resolved` (v1 and v2 formats). |
| `GitOperations` | Hardened `git ls-remote` lookups: no shell, protocol allow-list, bounded retries, credential redaction. |
| `SpmVersionUpdates::Semver` | Semver value object wrapping `semverify`. |
| `UpdateSeverity` / `FailOnThreshold` | Classifies updates as major/minor/patch and evaluates `fail-on` thresholds. |
| `RepositoryUpdateRules` | Per-repository YAML rules (`repo-rules-path`). |
| `RepositoryLink` | Compare/release links for GitHub, GitLab, and Bitbucket. |
| `VersionTagsPersistentCache` | Optional on-disk cache of tag lookups. |

Internal collaborators (`AllowHostNormalizer`, `GitHostNormalizer`,
`VersionTagFetcher`) are tagged `@api private` and hidden from the published
API docs.

## Danger plugin gem: `danger-spm_version_updates`

Location: `gems/danger-spm_version_updates/`. Published to RubyGems as
[`danger-spm_version_updates`](https://rubygems.org/gems/danger-spm_version_updates),
with a runtime dependency on the core gem.

`Danger::DangerSpmVersionUpdates` (`lib/spm_version_updates/plugin.rb`) exposes
the Dangerfile API (`check_for_updates`, `check_manifests`, and the
`check_when_exact`-style accessors) and delegates the actual checking to the
core gem. Reporting goes through Danger's `warn`/`fail` messaging. The gem
contains no checking logic of its own — the `Git`/`Xcode` helper modules from
`v0.2.0` were removed in favor of the core gem's `GitOperations`,
`XcodeParser`, and `XcodeProjectPackageReader`.

## GitHub Action layer: `action/`

Location: `action/lib/`, wired up by the repository-root `action.yml`
(composite action). Not published as a gem — it is consumed by pinning the
action ref, and its bundle installs the core gem from the in-repo path.

| Component | Responsibility |
| --- | --- |
| `Action` (`action.rb`) | Entry point. Reads `INPUT_*` environment variables, validates the source mode (Xcode project vs Swift manifest), runs the core checker. |
| `ActionReporter` | Writes step outputs (`updates-found`, `updates-json`, …), the step summary, and workflow annotations. |
| `ReporterSink` | Interface for external report destinations (`publish_updates`, `publish_success`, `clear`, optional tracking-issue support). |
| `GithubIntegration` | `ReporterSink` implementation that posts/updates/deletes the single generated PR comment via Octokit. |

New report destinations implement `ReporterSink` without touching the checker
or the reporting flow.

## Release flow

`rake 'bump[X.Y.Z]'` performs the version bump: it rewrites the single
`VERSION` constant (`gems/spm_version_updates/lib/spm_version_updates/version.rb`),
regenerates every `Gemfile.lock` that embeds the path-gem version, commits, and
creates the `vX.Y.Z` tag locally. Pushing that tag starts the release.

A `v*.*.*` tag triggers `push_gem.yml`, which releases the core gem first
(waiting for it to propagate so the plugin gem's dependency resolves), then the
Danger plugin gem. The floating major tag (e.g. `v1`) is moved only after both
gems are live on RubyGems. The same tag also triggers `docs.yml`, which
publishes per-layer API documentation to GitHub Pages.
