# SwiftPM-first projects: Swift package manifest mode

A usage and migration guide for repositories whose Swift Package Manager
dependencies live in `Package.swift` manifests rather than as
`XCRemoteSwiftPackageReference` objects inside an `.xcodeproj`.

If your app still builds through an Xcode project but the **source of truth for
dependencies** is one or more `Package.swift` files, this guide is for you.

## The scenario

A typical modular iOS repo looks like this:

```text
podcasts.xcodeproj/
Modules/Package.swift
Modules/Package.resolved
BuildTools/Package.swift
BuildTools/Package.resolved
```

The main `podcasts.xcodeproj` has an empty `packageReferences` section — the real
dependencies are declared in `Modules/Package.swift` and `BuildTools/Package.swift`,
and the resolved pins live in the `Package.resolved` file next to each manifest.

Pointing the action at `podcasts.xcodeproj` in this layout doesn't work well: the
`.xcodeproj` owns no remote package references, so the action finds nothing to
check. If an Xcode-adjacent `Package.resolved` exists, the action logs a warning
that the project may need manifest mode; otherwise `Package.resolved` is not in
any Xcode-adjacent workspace location.

## TL;DR — the workflow you want

```yaml
name: Swift Package Version Updates

on:
  pull_request:
    paths:
      - "Modules/Package.swift"
      - "Modules/Package.resolved"
      - "BuildTools/Package.swift"
      - "BuildTools/Package.resolved"
      - ".github/workflows/spm-version-updates.yml"
  workflow_dispatch:

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

No temporary Xcode project. No synthetic `Package.resolved`. No repo-specific
parser. No macOS runner — manifest parsing is pure Ruby and runs on
`ubuntu-latest` without a Swift or Xcode toolchain. Manifest mode also skips the
`xcodeproj` runtime dependency during action setup.

### Fork pull requests

Fork PRs need extra care if you switch the trigger to `pull_request_target` so
the action can write a summary comment. With that trigger, checking out the PR
head makes `Package.swift` untrusted input: a malicious fork can change package
URLs, and this action will ask `git ls-remote` to contact those remotes over
Git's `https`, `ssh`, or `git` transports. `file`, `ext`, and remote-helper
transports are blocked. Keep checkout credentials off, avoid extra secrets or
SSH keys, and set `allow-hosts` to the git hosts your manifests are expected to
use:

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

## Migrating from the synthetic-`.xcodeproj` workaround

Before manifest mode existed, repos in this layout had to bridge the gap with a CI
helper that would:

1. read `Modules/Package.swift` and `BuildTools/Package.swift`,
2. extract the `.package(...)` declarations,
3. generate a temporary `.xcodeproj`,
4. inject synthetic `XCRemoteSwiftPackageReference` objects,
5. merge both `Package.resolved` files, and
6. write the merged file to a path the action understood, e.g.
   `.spm-version-updates/PackageChecks.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

The action now does all of this natively, so that adapter can be deleted.

**Migration steps:**

1. **Switch the action inputs.** Replace `xcode-project-path:` (pointed at the
   generated project) with `package-manifest-paths:` listing your real manifests:

   ```diff
        - uses: hbmartin/github-action-spm_version_updates@v1
          with:
   -        xcode-project-path: .spm-version-updates/PackageChecks.xcodeproj
   +        package-manifest-paths: |
   +          Modules/Package.swift
   +          BuildTools/Package.swift
   ```

2. **Delete the generator step** from your workflow (the step that built the
   synthetic project before invoking the action).

3. **Delete the helper script and its output** from the repo, e.g. the
   `.spm-version-updates/` directory and any committed `PackageChecks.xcodeproj`.
   Add `.spm-version-updates/` to `.gitignore` if it was ever generated locally.

4. **Update the `on.pull_request.paths` filter** to watch the manifests and
   resolved files directly (see the workflow above) instead of the generated
   project.

That's the whole migration — everything else (constraint handling, PR comment
formatting) behaves the same.

## How `Package.resolved` is located

By default, the action reads the `Package.resolved` that sits **next to each
manifest**:

| Manifest | Inferred resolved file |
| --- | --- |
| `Modules/Package.swift` | `Modules/Package.resolved` |
| `BuildTools/Package.swift` | `BuildTools/Package.resolved` |

Every expected resolved file **must exist** — if one is missing the action fails
and names the missing file, rather than silently producing incomplete results.

If your resolved files live elsewhere, list them explicitly with
`package-resolved-paths`:

```yaml
        with:
          package-manifest-paths: |
            Modules/Package.swift
            BuildTools/Package.swift
          package-resolved-paths: |
            Modules/Package.resolved
            BuildTools/Package.resolved
```

Pins from every resolved file are merged into a single lookup keyed by normalized
repository URL, so a dependency declared in one manifest will match its pin
wherever it is recorded.

## Supported `.package(...)` declaration forms

Manifests are parsed with a lightweight scanner that understands the common
SwiftPM forms:

```swift
.package(url: "https://github.com/foo/bar", from: "1.2.3")
.package(url: "https://github.com/foo/bar", exact: "1.2.3")
.package(url: "https://github.com/foo/bar", branch: "main")
.package(url: "https://github.com/foo/bar", revision: "abcdef")
.package(url: "https://github.com/foo/bar", "1.0.0"..<"2.0.0")
.package(url: "https://github.com/foo/bar", "1.0.0"..."2.0.0")
.package(url: "https://github.com/foo/bar", .upToNextMajor(from: "1.2.3"))
.package(url: "https://github.com/foo/bar", .upToNextMinor(from: "1.2.3"))
.package(url: "https://github.com/foo/bar", .exact("1.2.3"))
```

Notes:

- Local packages (`.package(path: ...)`) and any declarations inside `//` or
  `/* */` comments (including nested block comments) are ignored.
- A closed range `"1.0.0"..."2.0.0"` is normalized the same way SwiftPM does — to
  the half-open range `"1.0.0"..<"2.0.1"` — so the inclusive upper bound is
  preserved.

## How each constraint is handled

| Constraint | Manifest form | Behavior |
| --- | --- | --- |
| Up to next major | `from:` / `.upToNextMajor(from:)` | Reports newer versions within the same major version. |
| Up to next minor | `.upToNextMinor(from:)` | Reports newer versions within the same major **and** minor version. |
| Version range | `"1.0.0"..<"2.0.0"` | Reports newer versions below the maximum. |
| Exact | `exact:` / `.exact(...)` | Skipped unless `check-when-exact: true`. |
| Branch | `branch:` / `.branch(...)` | Reports newer commits on the branch unless `check-branches: false`. |
| Revision | `revision:` / `.revision(...)` | Skipped unless `check-revisions: true`. A pinned commit has no general "newer" version, so when enabled the action only reports the latest tagged release for reference. |

A mix of `from`, `branch`, `revision`, and `exact` constraints in the same repo is
fully supported. Toggle the relevant behaviors explicitly:

```yaml
        with:
          package-manifest-paths: |
            Modules/Package.swift
            BuildTools/Package.swift
          check-when-exact: false
          check-branches: true
          check-revisions: false
```

When `report-above-maximum: true`, the action additionally surfaces the newest
version that exists *above* your constraint (for example a new major release your
`from:`/range would not pick up). Pre-release versions are excluded from reports
unless you set `report-pre-releases: true`.

## Multiple manifests and source attribution

When you pass more than one manifest, every warning is annotated with the manifest
it came from, so you know exactly where to make the change:

```text
⚠️ Found 2 potential dependency updates:

1. Newer version of onevcat/Kingfisher: 8.0.0
   Source: Modules/Package.swift
2. Newer version of SwiftGen/SwiftGenPlugin: 6.7.0
   Source: BuildTools/Package.swift
```

(The `Source:` line appears only in manifest mode.)

## Configuration reference

| Input | Description | Default |
| --- | --- | --- |
| `package-manifest-paths` | Newline-separated list of `Package.swift` paths. Provide this **or** `xcode-project-path`. | |
| `package-resolved-paths` | Optional newline-separated list of `Package.resolved` paths. Defaults to a `Package.resolved` next to each manifest. | inferred |
| `xcode-project-path` | Path to an `.xcodeproj` (classic mode). Provide this **or** `package-manifest-paths`. | |
| `check-when-exact` | Check for updates even when using `exact` constraints. | `false` |
| `check-branches` | Check for newer commits on branch-pinned dependencies. | `true` |
| `check-revisions` | Report the latest tagged version for revision-pinned dependencies. | `false` |
| `report-above-maximum` | Report versions above the maximum constraint range. | `false` |
| `report-pre-releases` | Include pre-release versions in update reports. | `false` |
| `ignore-repos` | Comma-separated list of repository URLs to ignore. | `''` |
| `repo-rules-path` | Path to a YAML file with per-repository semantic update suppression rules. | `''` |
| `allow-hosts` | Comma-separated list of git remote hostnames allowed for enabled version lookups. Empty allows any host for the allowed git protocols. A blocked lookup fails the action and writes `blocked=true` plus `error-message`. | `''` |
| `comment-on-success` | Post an up-to-date pull request comment on clean runs. By default, clean runs delete the prior generated comment instead. | `false` |
| `cache-version-tags` | Persist successful git tag lookups between runs with `actions/cache`. | `true` |
| `version-tags-cache-ttl` | Freshness window, in seconds, for persisted git tag lookups. Set `0` to disable persistent cache reads and writes. | `21600` |
| `setup-ruby` | Set up Ruby and install this action's bundle. Set to `false` only for later invocations in the same job after an earlier invocation has already run setup. | `true` |
| `github-token` | GitHub token for posting the PR comment. | `${{ github.token }}` |

Provide **exactly one** of `package-manifest-paths` or `xcode-project-path`.
Supplying both (or neither) fails with a clear error.

When invoking the action more than once in a job, keep `setup-ruby` enabled on
the first invocation and use `setup-ruby: false` on later manifest-mode
invocations to avoid repeating Ruby setup and Bundler cache work.

### Per-repository rules

`ignore-repos` still skips a dependency entirely before lookup. For dependencies
that should still be checked but should not report selected semantic updates, set
`repo-rules-path` to a YAML file:

```yaml
repositories:
  - url: "https://github.com/example/noise"
    ignore-until: "2.0.0"

  - url: "https://github.com/example/no-major"
    allowed-updates: "minor"
```

`ignore-until` reports version X and newer, while suppressing lower available
versions. `allowed-updates: minor` allows patch and minor reports but suppresses
major reports. Rules apply only to semantic `version` and `above_maximum`
reports; branch and revision reports use their existing controls.

## Using the Danger plugin

Manifest mode is also available in the [`danger-spm_version_updates`](https://rubygems.org/gems/danger-spm_version_updates)
plugin for repos that already run [Danger](https://danger.systems/ruby/):

```ruby
spm_version_updates.check_manifests(["Modules/Package.swift", "BuildTools/Package.swift"])
```

`check_manifests` accepts a single path or a list, plus an optional second
argument with explicit `Package.resolved` paths (by default a `Package.resolved`
next to each manifest is used). Warnings include Compare/Releases links, the
originating manifest, and a ready-to-run `swift package update` command. The
plugin accessors mirror the action inputs of the same name; see the
[README](../README.md#danger-plugin).

## A note on versioning

Examples above pin to `@v1`. Pinning to the major tag means you automatically
receive backward-compatible updates. You can also pin to an exact release (e.g.
`@v1.0.0`) or to a commit SHA for maximum reproducibility.

## Still using a classic Xcode project?

Manifest mode is purely additive. If your `.xcodeproj` directly owns its remote
package references, keep using `xcode-project-path` — that mode is unchanged. See
the main [README](../README.md) for details on both modes.
