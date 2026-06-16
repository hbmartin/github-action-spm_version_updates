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

# Manifest mode: check one or more Package.swift files.
result = checker.check_manifests(["path/to/Package.swift"])

# Xcode mode: check the packages referenced by an Xcode project.
# result = checker.check_for_updates("path/to/App.xcodeproj")

result.updates.each { |update| puts update["message"] }

# String-keyed details include repository URL, current/available version,
# suggested update command, source, and related report fields.
result.updates.each { |update| p update }
```

Behavior is configurable through accessors on `SpmChecker` — for example
`check_when_exact`, `check_branches`, `report_above_maximum`,
`report_pre_releases`, `ignore_repos`, and allow-host restrictions. See the
class documentation for the full list.

## Errors

Everything the gem raises descends from one of two roots (defined in
`lib/spm_version_updates/errors.rb`), so callers can rescue by failure
category instead of enumerating concrete classes:

- **`SpmVersionUpdates::Error < StandardError`**
  - **`FileNotFoundError`** — a required file is missing:
    - `ManifestParser::CouldNotFindManifest` — a `Package.swift` path does
      not exist.
    - `ManifestParser::CouldNotFindResolvedFile` — an expected
      `Package.resolved` is missing in manifest mode; the message names the
      missing file(s). Raised rather than silently reporting incomplete
      results.
    - `XcodeParser::CouldNotFindResolvedFile` — no `Package.resolved` was
      found in the Xcode workspace locations.
  - **`ParseError`** — a file exists but could not be read:
    - `PackageResolved::MalformedFileError` — a corrupt or unrecognized
      `Package.resolved`.
  - **`NetworkError`** — git lookup failures:
    - `GitOperations::LsRemoteError` — `git ls-remote` failed after bounded
      retries (unreachable host, authentication failure). Messages are
      credential-redacted.
  - **`PolicyError`** — security-gate violations:
    - `SpmChecker::DisallowedRepositoryHost` — `allow_hosts` is configured
      and a dependency's host is not on the list. Raised before git is
      contacted.
- **`SpmVersionUpdates::ConfigurationError < ArgumentError`** — invalid
  caller-supplied configuration: `ManifestParser::ManifestPathMustBeSet`,
  `XcodeParser::XcodeprojPathMustBeSet`, `allow_hosts` entries that don't
  parse as hostnames, and every invalid repo-rules YAML shape. It inherits
  `ArgumentError` (not `Error`) so existing callers that rescue
  `ArgumentError` keep working — rescue it alongside
  `SpmVersionUpdates::Error` when catching everything the gem raises:

```ruby
begin
  checker.check_manifests(["Modules/Package.swift"])
rescue SpmVersionUpdates::ConfigurationError, SpmVersionUpdates::Error => error
  abort(error.message)
end
```

## Continuing past per-dependency failures

By default, the first failed git lookup or malformed `Package.resolved`
raises and aborts the run. Two optional handlers turn those into callbacks so
the remaining dependencies keep being checked:

```ruby
# Called as (package, error) instead of raising GitOperations::LsRemoteError.
# A dependency shared by several manifests is reported only once per run.
checker.lookup_failure_handler = ->(package, error) {
  puts("Skipping #{package.name}: #{error.message}")
}

# Called as (resolved_path, error) instead of raising
# PackageResolved::MalformedFileError; the file's pins are skipped.
checker.malformed_resolved_handler = ->(path, error) {
  puts("Ignoring #{path}: #{error.message}")
}
```

## Parse warnings

A `.package(...)` declaration whose version requirement isn't recognized (or
that has unbalanced parentheses) is skipped rather than guessed at. Each skip
is recorded on the checker — separate from update warnings, so update counts
and fail-on thresholds are unaffected:

```ruby
result = checker.check_manifests(["Modules/Package.swift"])

result.parse_warnings.each do |record|
  # String-keyed hash: "type" ("parse_warning"), "reason", "source"
  # (the manifest path), "snippet" (credential-redacted, truncated),
  # and a human-readable "message".
  puts(record["message"])
  puts(ParseWarning.describe_reason(record))  # the reason as a readable phrase
  puts(ParseWarning.issue_link(record))       # pre-filled GitHub new-issue URL
end
```

The snippet is redacted and shown in the report only — it is never embedded
in the issue URL, where it could leak private repository URLs.

## License

MIT — see [LICENSE.txt](LICENSE.txt).
