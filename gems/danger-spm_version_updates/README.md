# danger-spm_version_updates

A [Danger](https://danger.systems/ruby/) plugin to detect if there are any
updates to your Swift Package Manager dependencies. It supports both source
modes — Xcode projects and `Package.swift` manifests — and requires
Ruby >= 3.2.

The version-checking logic lives in the
[`spm_version_updates`](https://rubygems.org/gems/spm_version_updates) core
gem; this plugin is a thin Danger wrapper around it. The same checker also
powers the
[Swift Package Version Updates GitHub Action](https://github.com/hbmartin/danger-spm_version_updates),
if you'd rather run dependency checks as a standalone action.

## Installation

Add it to your Gemfile:

```ruby
gem "danger-spm_version_updates"
```

## Usage

Call it from your `Dangerfile`:

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

`check_manifests` accepts a single path or a list, and an optional second
argument with explicit `Package.resolved` paths (by default a
`Package.resolved` next to each manifest is used). Each available update is
reported as a Danger `warn` that includes Compare/Releases links for supported
hosts, the originating manifest, and a ready-to-run `swift package update`
command in manifest mode.

The configurable accessors are: `check_when_exact`, `check_branches`,
`check_revisions`, `report_above_maximum`, `report_pre_releases`,
`ignore_repos`, and `repo_rules_path`.

## License

MIT — see [LICENSE.txt](LICENSE.txt).
