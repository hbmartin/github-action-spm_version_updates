# Troubleshooting

Common failure modes and what they mean. Each section heading is a symptom.

## No comment appeared on my PR

Check that the job has `pull-requests: write` and that the run is a real pull
request — fork PRs get a read-only token and can't comment (see the
[security guide](security.md)). On clean runs the prior comment is deleted by
default; set `comment-on-success: true` to keep an "up to date" comment
instead. `comment: false` disables PR commenting entirely.

## No tracking issue appeared on my scheduled run

Tracking issues require `open-tracking-issue: true`, the `issues: write`
permission, and a run *without* a pull request context — PR runs always use
the PR comment instead. Check `tracking-issue-url` in the step outputs to
confirm whether one was touched.

## The action failed with a missing `Package.resolved`

In Swift manifest mode every manifest needs a resolved file next to it (e.g.
`Modules/Package.swift` → `Modules/Package.resolved`). The action fails
loudly rather than silently reporting incomplete results. Commit the resolved
file, or point `package-resolved-paths` at its real location.

## No updates found, but I know a newer version exists

Updates are detected from semver-style tags. By design, the following are
skipped unless opted in:

- pre-releases (`report-pre-releases: true`)
- versions above your declared constraint (`report-above-maximum: true`)
- exact pins (`check-when-exact: true`)
- revision pins (`check-revisions: true`)

A dependency that doesn't publish version tags produces no updates, and
`ignore-repos` or `repo-rules-path` may be suppressing the report (see the
[repository rules reference](repo-rules.md)).

## The `parse-warnings` output is non-zero / a dependency is missing from the report

A `.package(...)` declaration whose version requirement the parser doesn't
recognize (or that has unbalanced parentheses) is skipped rather than guessed
at. Skipped declarations are listed in the step summary and PR comment with a
pre-filled link to open an issue — if the declaration is valid Swift, please
report it.

## The output says `blocked=true`

A dependency's host isn't in `allow-hosts`. Add the host (matching is exact
and case-insensitive) or adjust your manifests; the `error-message` output
names what was blocked.

## It can't reach a private dependency

The runner must already be authenticated (SSH key or git credentials) to
fetch private repos — the action doesn't manage credentials. Unreachable or
auth-failing dependencies fail the run after bounded retries rather than
reporting "no updates."

## "Provide exactly one of…" error

Set either `xcode-project-path` **or** `package-manifest-paths` — not both,
and not neither.

## A later invocation in the same job failed before checking anything

`setup-ruby: false` skips Ruby setup and the bundle install, so it's only
valid after an earlier invocation in the same job has already run setup with
the same source mode (or a superset of the runtime dependencies). The action
checks for Ruby, Bundler, and installed gems up front and fails with a clear
error instead of a Bundler backtrace when the earlier setup is missing.
