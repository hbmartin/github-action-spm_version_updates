# Migration guide: `v0.2.0` to `v1`

This guide covers the user-facing and maintainer-facing changes between the
`v0.2.0` release and the `v1` action tag.

The short version: `v0.2.0` was documented as a Danger plugin. `v1` adds a
first-class GitHub Action, a new Swift manifest source mode, structured GitHub
Actions outputs, stricter git lookup behavior, and a higher Ruby requirement.
Along the way the project was split into layers: a dependency-checking core
gem, a thin Danger plugin gem on top of it, and the GitHub Action runner (see
[architecture.md](architecture.md)).

## Who needs to change something?

| If you are... | What changed | What to do |
| --- | --- | --- |
| Running the old Danger plugin from a `Dangerfile` | The plugin API still exists, but the project is now centered on the GitHub Action. | You can keep `spm_version_updates.check_for_updates("App.xcodeproj")`, but update Ruby and dependencies. |
| Moving from Danger to the GitHub Action | `action.yml` is new in `v1`. | Replace the Danger invocation with a workflow step using `xcode-project-path` or `package-manifest-paths`. |
| Checking dependencies from `Package.swift` files | Swift manifest mode did not exist in `v0.2.0`. | Use `package-manifest-paths` and make sure each manifest has a matching `Package.resolved`, or set `package-resolved-paths`. |
| Consuming GitHub Actions outputs | Outputs did not exist in `v0.2.0`. | Read `updates-found`, severity counts, `updates-json`, `blocked`, and `error-message` from the action step. |
| Maintaining this repository locally | The runtime and quality toolchain changed. | Use Ruby 3.2 or newer, preferably Ruby 3.3, and run the expanded spec/lint suite. |

## Breaking and compatibility notes

### One project, two gems

`v0.2.0` shipped as a single gem, `danger-spm_version_updates`. The project is
now layered:

| Layer | Where | Published as |
| --- | --- | --- |
| Core checking logic | `gems/spm_version_updates/` | [`spm_version_updates`](https://rubygems.org/gems/spm_version_updates) on RubyGems |
| Danger plugin | `gems/danger-spm_version_updates/` | [`danger-spm_version_updates`](https://rubygems.org/gems/danger-spm_version_updates) on RubyGems |
| GitHub Action runner | `action/` + `action.yml` | Not a gem; consumed via the action ref |

`danger-spm_version_updates` declares a runtime dependency on
`spm_version_updates`, so Bundler installs both — no Gemfile change is needed
beyond updating the version. If your own tooling consumes the checking logic
programmatically (parsers, git lookups, semver classification), depend on the
core gem directly instead of the Danger plugin gem.

Per-layer API documentation is published to GitHub Pages on every release:
<https://hbmartin.github.io/github-action-spm_version_updates/>.

### Removed `v0.2.0` helper modules

The `Git` and `Xcode` helper modules that `v0.2.0` exposed from the Danger gem
have been removed. The Dangerfile API (`check_for_updates`, `check_manifests`,
and the configuration accessors) is unaffected, but code that called the
helpers directly must switch to the core gem's equivalents:

| Removed | Replacement (core gem) |
| --- | --- |
| `Git.trim_repo_url`, `Git.repo_name`, `Git.version_tags`, `Git.branch_last_commit` | `GitOperations` (same method names) |
| `Xcode.get_packages` | `XcodeProjectPackageReader.package_references` |
| `Xcode.get_resolved_versions` | `XcodeParser` / `PackageResolved.versions_from` |
| `Xcode::XcodeprojPathMustBeSet`, `Xcode::CouldNotFindResolvedFile` | `XcodeParser::XcodeprojPathMustBeSet`, `XcodeParser::CouldNotFindResolvedFile` |
| `require "spm_version_updates/gem_version"` | `require "spm_version_updates/version"` |

Note that `GitOperations` lookups raise `GitOperations::LsRemoteError` after
bounded retries instead of returning empty results on failure, and return
`SpmVersionUpdates::Semver` values rather than `Semantic::Version`.

### Ruby requirement

The gemspec now requires Ruby `>= 3.2`; `v0.2.0` required Ruby `>= 3.0`.
GitHub Actions runs the composite action with Ruby `3.3`.

If your CI still runs Ruby 3.0 or 3.1 for this project, update it before
upgrading:

```yaml
- uses: ruby/setup-ruby@afeafc3d1ab54a631816aba4c914a0081c12ff2f
  with:
    ruby-version: "3.3"
    bundler-cache: true
```

### Semver dependency

The Ruby dependency changed from `semantic` to `semverify`. If you vendor or pin
the gem through Bundler, refresh the lockfile after upgrading:

```sh
bundle update danger-spm_version_updates
```

If your own `Gemfile` pinned `semantic` only for this project, remove that direct
pin. Add a direct `semverify` pin only if your own code needs to use it.

Do not rely on internal `Semantic::Version` objects from this project. The
version wrapper in `v1` returns `SpmVersionUpdates::Semver` values internally.
If you consume the code directly from git, pin the git tag explicitly:

```ruby
gem "danger-spm_version_updates",
    git: "https://github.com/hbmartin/github-action-spm_version_updates.git",
    tag: "v1"
```

## Path 1: keep using the Danger plugin

The existing Dangerfile call remains the same:

```ruby
spm_version_updates.check_for_updates("Example.xcodeproj")
```

The existing Danger plugin configuration names are still available:

```ruby
spm_version_updates.check_when_exact = true
spm_version_updates.report_above_maximum = true
spm_version_updates.report_pre_releases = true
spm_version_updates.ignore_repos = [
  "https://github.com/pointfreeco/swift-snapshot-testing",
]
spm_version_updates.repo_rules_path = ".github/spm-version-rules.yml"
```

Important limitations if you stay on the Danger plugin:

- The `Git` and `Xcode` helper modules are gone; see
  [Removed `v0.2.0` helper modules](#removed-v020-helper-modules) if your
  Dangerfile called them directly.
- It remains Xcode-project mode only. It does not expose `package-manifest-paths`.
- It does not expose GitHub Actions outputs, step summaries, annotations,
  `fail-on`, `allow-hosts`, or `comment-on-success`.
- It now uses the safer git lookup path and semver adapter, so some malformed
  version tags or git URLs that previously behaved inconsistently may now be
  ignored or logged instead.

## Path 2: migrate to the GitHub Action

Replace the Danger step with the composite action. For a classic Xcode project,
the minimal workflow is:

```yaml
name: Check SPM Dependencies

on:
  pull_request:
    paths:
      - "**/*.xcodeproj/**"
      - "**/Package.resolved"
      - ".github/workflows/spm-version-updates.yml"

permissions:
  contents: read
  pull-requests: write

jobs:
  spm-updates:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hbmartin/github-action-spm_version_updates@v1
        with:
          xcode-project-path: "MyApp.xcodeproj"
```

The action reads files from the checked-out workspace, posts or updates one pull
request comment, writes a step summary, and exposes machine-readable outputs.

The `v1` major tag should point at the latest backward-compatible v1 release.
Pin `@v1.0.0` or a commit SHA when you need fully reproducible installs.

## Source mode migration

`v1` has two source modes. You must provide exactly one of them:

| Mode | Input | Use it when |
| --- | --- | --- |
| Xcode project mode | `xcode-project-path` | The `.xcodeproj` directly owns its `XCRemoteSwiftPackageReference` objects. |
| Swift manifest mode | `package-manifest-paths` | Dependencies live in one or more `Package.swift` files. |

Providing both inputs, or neither input, fails with a clear error.

### Xcode project mode

If `v0.2.0` worked for your Xcode project, use `xcode-project-path`:

```yaml
- uses: hbmartin/github-action-spm_version_updates@v1
  with:
    xcode-project-path: "MyApp.xcodeproj"
```

`v1` still searches the Xcode-adjacent `Package.resolved` locations:

```text
MyApp.xcworkspace/xcshareddata/swiftpm/Package.resolved
MyApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
```

When both files exist, pins are merged. Blank repository URLs are ignored.

### Swift manifest mode

Use this mode when the source of truth is `Package.swift`:

```yaml
- uses: hbmartin/github-action-spm_version_updates@v1
  with:
    package-manifest-paths: |
      Modules/Package.swift
      BuildTools/Package.swift
```

By default, each manifest must have a `Package.resolved` next to it:

| Manifest | Default resolved file |
| --- | --- |
| `Modules/Package.swift` | `Modules/Package.resolved` |
| `BuildTools/Package.swift` | `BuildTools/Package.resolved` |

If your resolved files live somewhere else, list them explicitly:

```yaml
- uses: hbmartin/github-action-spm_version_updates@v1
  with:
    package-manifest-paths: |
      Modules/Package.swift
      BuildTools/Package.swift
    package-resolved-paths: |
      .swiftpm/modules/Package.resolved
      .swiftpm/build-tools/Package.resolved
```

Every expected resolved file must exist. Missing files fail the action instead
of silently reporting incomplete results.

### Migrating away from a generated Xcode project

If you previously generated a temporary `.xcodeproj` only so `v0.2.0` could read
SPM dependencies, delete that workaround:

```diff
 - uses: hbmartin/github-action-spm_version_updates@v1
   with:
-    xcode-project-path: .spm-version-updates/PackageChecks.xcodeproj
+    package-manifest-paths: |
+      Modules/Package.swift
+      BuildTools/Package.swift
```

Then remove the generator step, remove any generated `.spm-version-updates/`
output from the repository, and update your workflow `paths:` filters to watch
the real `Package.swift` and `Package.resolved` files.

## Configuration mapping

| `v0.2.0` Danger config | `v1` action input | Notes |
| --- | --- | --- |
| `check_when_exact = true` | `check-when-exact: true` | Exact pins are skipped by default. |
| `report_above_maximum = true` | `report-above-maximum: true` | Reports releases above the configured range, such as a new major version. |
| `report_pre_releases = true` | `report-pre-releases: true` | Pre-release tags are ignored by default. |
| `ignore_repos = ["url"]` | `ignore-repos: "url"` | Use a comma-separated list for multiple repositories. |
| `repo_rules_path = "path"` | `repo-rules-path: "path"` | YAML rules can suppress semantic reports per repository without skipping lookups. |
| No equivalent | `xcode-project-path` | Required for Xcode project mode. |
| No equivalent | `package-manifest-paths` | Required for Swift manifest mode. |
| No equivalent | `package-resolved-paths` | Optional override for manifest mode. |
| No equivalent | `check-branches` | Defaults to `true`. |
| No equivalent | `check-revisions` | Defaults to `false`. |
| No equivalent | `allow-hosts` | Restricts git remotes contacted during enabled lookups. |
| No equivalent | `fail-on-updates` | Legacy action failure behavior: `true` means fail on any reported update. |
| No equivalent | `fail-on` | Preferred semantic threshold: `major`, `minor`, or `patch`. |
| No equivalent | `comment-on-success` | Defaults to `false`; clean runs delete the previous generated comment. |
| No equivalent | `github-token` | Defaults to `${{ github.token }}`. |

Example with most options enabled:

```yaml
- id: spm-updates
  uses: hbmartin/github-action-spm_version_updates@v1
  with:
    package-manifest-paths: |
      Modules/Package.swift
      BuildTools/Package.swift
    check-when-exact: true
    check-branches: true
    check-revisions: false
    report-above-maximum: true
    report-pre-releases: false
    ignore-repos: "https://github.com/pointfreeco/swift-snapshot-testing"
    repo-rules-path: ".github/spm-version-rules.yml"
    allow-hosts: "github.com,gitlab.com"
    fail-on: major
```

## Reporting changes

`v1` writes results in several places:

| Destination | Behavior |
| --- | --- |
| Pull request comment | Updates one generated comment when updates are found. |
| Clean pull request run | Deletes the previous generated comment by default. Set `comment-on-success: true` to keep an up-to-date success comment. |
| Step summary | Always writes a human-readable summary. |
| Workflow annotations | Emits `warning` annotations for updates and an `error` annotation for blocked runs. |
| Step outputs | Always writes machine-readable outputs when `GITHUB_OUTPUT` is available. |

The outputs are:

| Output | Meaning |
| --- | --- |
| `updates-found` | Total reported updates. |
| `major-updates-found` | Count of semantic version updates classified as major. |
| `minor-updates-found` | Count of semantic version updates classified as minor. |
| `patch-updates-found` | Count of semantic version updates classified as patch. |
| `updates-json` | JSON array of update records. |
| `blocked` | `true` when a security gate such as `allow-hosts` stops the run before lookup. |
| `error-message` | Failure message for blocked runs. |

`updates-json` records include a `message` field and, when structured details
are available, fields such as `type`, `package`, `repository_url`,
`current_version`, `available_version`, `severity`, `note`, and `source`.
Credentials embedded in `repository_url` are redacted.

If you use a fail option, read outputs from later steps with `always()` because
the action can intentionally fail after reporting:

```yaml
- id: spm-updates
  uses: hbmartin/github-action-spm_version_updates@v1
  with:
    xcode-project-path: "MyApp.xcodeproj"
    fail-on: major

- name: Print update JSON
  if: ${{ always() && steps.spm-updates.outputs.updates-found != '0' }}
  run: echo '${{ steps.spm-updates.outputs.updates-json }}'
```

## Failure behavior

`fail-on-updates: true` fails the job when any update is reported, including
branch and revision reports.

Prefer `fail-on` for semantic version thresholds:

| Input | Fails on |
| --- | --- |
| `fail-on: major` | Major semantic updates only. |
| `fail-on: minor` | Major or minor semantic updates. |
| `fail-on: patch` | Major, minor, or patch semantic updates. |

The action writes outputs, the step summary, annotations, and any PR comment
before it exits with failure for a matching threshold.

## Security and git remote changes

Version checks still use `git ls-remote`, but `v1` hardens how git is called:

- Git is invoked without a shell and with `--` before the repository URL.
- `GIT_ALLOW_PROTOCOL` is set to `https:ssh:git`.
- `file`, `ext`, and remote-helper transports are blocked by git protocol policy.
- In the GitHub Action checker path, git lookup failures are logged and fail
  the action after bounded retries instead of being silently treated as a
  successful empty result.
- Credentials embedded in URLs are redacted in logs and JSON output.

Private dependencies still work if the runner is already authenticated for those
git remotes. The action does not install SSH keys or credentials for you.

### Using `allow-hosts`

Set `allow-hosts` when the dependency files are untrusted, especially in
`pull_request_target` workflows:

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

Host matching is exact and case-insensitive. Schemes, credentials, paths, and
ports are ignored during normalization. If every configured `allow-hosts` entry
is malformed, the action fails closed. A dependency on a disallowed host fails
before git is contacted and writes:

```text
blocked=true
updates-found=0
updates-json=[]
```

`allow-hosts` is enforced only for enabled lookups. For example, an off-list
exact dependency does not block the run while `check-when-exact` is `false`.

## Dependency constraint behavior

The defaults in `v1` are:

| Constraint type | Default behavior |
| --- | --- |
| `from:` / up-to-next-major | Check versions within the same major version. |
| up-to-next-minor | Check versions within the same major and minor version. |
| version range | Check versions below the maximum. |
| exact version | Skip unless `check-when-exact: true`. |
| branch | Check newer branch commits unless `check-branches: false`. |
| revision | Skip unless `check-revisions: true`. |
| pre-release tags | Ignore unless `report-pre-releases: true`. |
| above-maximum versions | Ignore unless `report-above-maximum: true`. |

Behavioral fixes and additions since `v0.2.0`:

- Swift manifest mode supports common `.package(...)` forms, including `from:`,
  `exact:`, `branch:`, `revision:`, `.upToNextMajor`, `.upToNextMinor`,
  `.exact`, `.branch`, `.revision`, and open or closed version ranges.
- Closed manifest ranges such as `"1.0.0"..."2.0.0"` are normalized to preserve
  the inclusive upper bound.
- Local manifest packages declared with `.package(path: ...)` are ignored.
- Declarations inside Swift line comments and nested block comments are ignored.
- `Package.resolved` v1 and v2 formats are both supported.
- Up-to-next-minor checks now require the same major and minor version, avoiding
  false matches such as `2.5.0` for a dependency resolved at `1.5.0`.
- Two-component tags such as `1.0` are normalized to `1.0.0` before parsing.
- Range and above-maximum reporting respect the pre-release filter.
- Revision pins are opt-in through `check-revisions`; when enabled, the action
  reports the latest tagged version for reference rather than claiming an
  arbitrary commit is definitely behind.
- Malformed package entries, nil requirements, nil repository URLs, and
  unparsable semver values are skipped or logged instead of crashing common
  runs.

## PR comment changes

The built-in action comment is generated through the GitHub-backed reporter
sink. It updates an existing generated comment instead of creating duplicates.
Additional sinks can implement `publish_updates`, `publish_success`, and
`clear` without changing the checker or action reporting flow.

When structured details are available, the comment groups duplicate package
updates and includes current and available versions, source manifests, and links
for supported hosts:

| Host | Links |
| --- | --- |
| GitHub | Compare and Releases |
| GitLab | Compare and Releases |
| Bitbucket | Compare and Tags |
| Other hosts | `N/A` |

For non-PR runs, or when the token cannot write comments, the step summary,
annotations, and outputs are still the reliable places to read results.

## Maintainer migration notes

Local development changed along with the action runtime:

- Use Ruby 3.2 or newer. The maintenance docs recommend Ruby 3.3+.
- Runtime dependencies are listed directly in `Gemfile`; development and test
  dependencies are grouped.
- `bundle exec rake spec` now includes Reek in addition to specs, RuboCop, and
  docs checks.
- CI now has separate lint and action-spec jobs.
- CI runs RuboCop, Reek, Danger plugin lint, and a pinned Semgrep rule.
- GitHub workflow actions are pinned by commit SHA and checkout uses
  `persist-credentials: false`.
- Coverage is uploaded as a workflow artifact instead of through Codecov.

Useful local checks:

```sh
bundle exec rspec
bundle exec rubocop
bundle exec rake reek
bundle exec danger plugins lint
bundle exec rake docs docs:check  # build the docs site, gate on coverage
```

API documentation builds per layer (core gem, Danger plugin, action runner)
into `_site/` via `rake docs`, and `docs.yml` publishes it to GitHub Pages
on every release tag.

To exercise the action entrypoint locally:

```sh
GITHUB_WORKSPACE="$(pwd)" \
  INPUT_XCODE_PROJECT_PATH=spec/support/fixtures/UpToNextMajor.xcodeproj \
  bundle exec ruby lib/action.rb
```

For manifest mode:

```sh
GITHUB_WORKSPACE="$(pwd)" \
  INPUT_PACKAGE_MANIFEST_PATHS="spec/support/manifests/Modules/Package.swift" \
  bundle exec ruby lib/action.rb
```

## Upgrade checklist

1. Update CI to Ruby 3.2 or newer.
2. Decide whether to keep the Danger plugin or move to the GitHub Action.
3. If using the action, add `permissions: contents: read` and
   `pull-requests: write`.
4. Configure exactly one source mode: `xcode-project-path` or
   `package-manifest-paths`.
5. Translate old Danger settings to action inputs if you moved to the action.
6. Add `allow-hosts` for untrusted PR workflows or locked-down runners.
7. Update downstream workflow logic to read the new step outputs.
8. Use `always()` on downstream output-reading steps when `fail-on` or
   `fail-on-updates` can fail the action.
9. Run the workflow once on a branch and confirm the PR comment, step summary,
   annotations, and outputs match your expectations.
