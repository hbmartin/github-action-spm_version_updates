# spm_version_updates

Core library for detecting available updates to Swift Package Manager
dependencies. It powers both the
[`danger-spm_version_updates`](https://rubygems.org/gems/danger-spm_version_updates)
Danger plugin and the
[Swift Package Version Updates GitHub Action](https://github.com/hbmartin/github-action-spm_version_updates),
and can be used directly from any Ruby program.

## Installation

```sh
gem install spm_version_updates
```

Xcode-project mode additionally requires the `xcodeproj` gem; manifest mode
has no extra dependencies.

## Usage

```ruby
require "spm_version_updates"

checker = SpmChecker.new

# Manifest mode: check one or more Package.swift files (a Package.resolved
# next to each manifest is used automatically when present).
warnings = checker.check_manifests(["path/to/Package.swift"])

# Xcode mode: check the packages referenced by an Xcode project.
# warnings = checker.check_for_updates("path/to/App.xcodeproj")

warnings.each { |warning| puts warning }

# Structured details (repository URL, current/available version, severity,
# suggested update command, ...) for each warning:
checker.warning_details.each { |detail| p detail }
```

Behavior is configurable through accessors on `SpmChecker` — for example
`check_when_exact`, `check_branches`, `report_above_maximum`,
`report_pre_releases`, `ignore_repos`, and allow-host restrictions. See the
class documentation for the full list.

## License

MIT — see [LICENSE.txt](LICENSE.txt).
