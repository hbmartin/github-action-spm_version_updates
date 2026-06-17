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
contains no checking logic of its own; it renders warnings from the structured
`SpmChecker::Result` returned by the core gem.

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

### One check run, end to end

```text
action.rb                          SpmChecker (core gem)
    │  read INPUT_* env vars            │
    │  ReporterSink#configure(inputs)   │
    │  check_manifests /                │
    │  check_for_updates ──────────────▶│
    │                                   │ ManifestParser / XcodeParser
    │                                   │   └─ .package(...) declarations
    │                                   │      (unparseable ones → parse_warnings)
    │                                   │ PackageResolved
    │                                   │   └─ resolved pins, merged by normalized URL
    │                                   │ VersionTagFetcher / GitOperations
    │                                   │   └─ git ls-remote per dependency
    │                                   │      (parallel workers, optional disk cache,
    │                                   │       allow-hosts gate before contact)
    │                                   │ Semver / UpdateSeverity
    │                                   │   └─ classify each update
    │                                   │ ignore-repos / RepositoryUpdateRules
    │                                   │   └─ filter suppressed reports
    │ ◀── result.updates, ─────────────┘
    │     result.parse_warnings
    │  ActionReporter
    │    └─ step outputs, step summary, ::warning annotations
    │  ReporterSink
    │    └─ publish_updates / publish_success / clear  ──▶  PR comment or
    │                                                       tracking issue
    │  FailOnThreshold
    │    └─ exit status (after everything above is written)
```

### Writing a custom `ReporterSink`

`Action` calls the sink at fixed points; implement these methods
(`action/lib/reporter_sink.rb`):

| Method | When it is called |
| --- | --- |
| `configure(inputs)` | Once, before checking, with the parsed inputs hash. Optional override. |
| `publish_updates(payload)` | Updates, parse warnings, or missing resolved files exist. Parse warnings force a publish even with zero updates, so a skipped declaration never reads as "all up to date". |
| `publish_success` | Clean run with `comment-on-success: true`. |
| `clear` | Clean run otherwise — retract a previously published report, if any. |
| `tracking_issue_run?` | Return `true` when the sink reports outside a PR, so publishing happens even with `comment: false`. Optional override (default `false`). |
| `tracking_issue_result` | `{ number:, url: }` of the issue touched by the last publish, or `nil`; feeds the `tracking-issue-*` outputs. Optional override. |

A minimal sink that posts to a Slack incoming webhook:

```ruby
require "json"
require "net/http"
require_relative "reporter_sink"

# Reports update warnings to a Slack channel instead of a PR comment.
class SlackSink < ReporterSink
  def configure(_inputs)
    @webhook_url = URI(ENV.fetch("SLACK_WEBHOOK_URL"))
  end

  def publish_updates(payload)
    messages = payload.updates.map { |update| update.fetch("message") }
    post("📦 SPM updates available:\n#{messages.join("\n")}")
  end

  def publish_success
    post(SUCCESS_MESSAGE)
  end

  def clear
    # Nothing to retract; Slack messages are immutable.
  end

  private

  def post(text)
    Net::HTTP.post(@webhook_url, JSON.generate(text:), "Content-Type" => "application/json")
  end
end
```

Wire it in by constructing the entry point with the sink:

```ruby
Action.new(reporter_sink: SlackSink.new).run
```

The structured update records (repository URL, current/available version,
severity, suggested update command, …) and the `parse_warnings` records are
available on the payload when the sink wants to render more than plain messages
— `GithubIntegration` is the in-tree example that uses both.

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
