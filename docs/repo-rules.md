# Per-repository update rules reference

The `repo-rules-path` action input (mirrored by the Danger plugin's
`repo_rules_path` accessor, and by `RepositoryUpdateRules.load_file` for
direct users of the core gem) points at a YAML file of per-repository rules
that suppress selected semantic-version reports while the dependency keeps
being checked.

## `ignore-repos` vs `repo-rules-path`

| You want to… | Use |
| --- | --- |
| Skip a dependency entirely, before any git lookup | `ignore-repos` |
| Keep checking a dependency, but hide reports below a known version | `repo-rules-path` with `ignore-until` |
| Keep checking a dependency, but hide reports above a severity | `repo-rules-path` with `allowed-updates` |

A suppressed report disappears everywhere: the PR comment, the step summary,
the `::warning` annotations, the count outputs and `updates-json`, and the
`fail-on` evaluation.

## File format

```yaml
repositories:
  - url: "https://github.com/example/noise"
    ignore-until: "2.0.0"

  - url: "https://github.com/example/no-major"
    allowed-updates: "minor"

  - url: "https://github.com/example/both"
    ignore-until: "1.4.0"
    allowed-updates: "patch"
```

- The root must be a mapping with a single `repositories` list.
- Each entry is a mapping with a required `url` and **at least one** of
  `ignore-until` or `allowed-updates`. When both are present, a report is
  suppressed if *either* rule suppresses it.
- The schema is strict: unknown keys (at the root or in an entry), duplicate
  `url` entries, a non-semver `ignore-until`, or an `allowed-updates` value
  other than `patch`/`minor`/`major` all fail the run with a configuration
  error naming the offending entry (e.g. `repositories[2]`).

## How `url` is matched

The rule's `url` and the dependency's repository URL are both normalized
before comparison: the scheme (`https://`, `ssh://`, …) and a trailing `.git`
are stripped. Everything that remains must match exactly. In practice: copy
the URL from your manifest — scheme and `.git` differences are tolerated, but
a different host, path, or capitalization is a different repository.

## `ignore-until`

Suppresses semantic reports whose available version is **below** the
configured version. The configured version itself still reports — "wake me
when 2.0 lands" is exactly `ignore-until: "2.0.0"`:

| Available version | `ignore-until: "2.0.0"` |
| --- | --- |
| `1.9.4` | suppressed |
| `2.0.0-rc.1` | suppressed (pre-release of 2.0.0 sorts below it) |
| `2.0.0` | reported |
| `2.1.0` | reported |

The value must be a semantic version, e.g. `"2.0.0"`.

## `allowed-updates`

Caps the severity of reports for that repository: `patch`, `minor`, or
`major`. Severity is computed from the current and available versions, and
reports **above** the cap are suppressed — `minor` allows patch and minor
reports but hides major ones; `major` allows everything (useful only combined
with `ignore-until`).

## Scope

Rules apply only to semantic reports — `version` and `above_maximum` types.
Branch and revision reports are controlled by `check-branches`,
`check-revisions`, and `ignore-repos` instead, and reports whose versions
don't parse as semver are never suppressed by these rules.

## Wiring it up

```yaml
- uses: hbmartin/github-action-spm_version_updates@v1
  with:
    package-manifest-paths: Modules/Package.swift
    report-above-maximum: true
    repo-rules-path: .github/spm-version-rules.yml
```

In a `Dangerfile`:

```ruby
spm_version_updates.repo_rules_path = ".github/spm-version-rules.yml"
```

From Ruby, against the core gem:

```ruby
checker.repository_update_rules = RepositoryUpdateRules.load_file(".github/spm-version-rules.yml")
```
