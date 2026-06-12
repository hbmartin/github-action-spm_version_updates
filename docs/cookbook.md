# Cookbook

Complete workflows for common setups. The [README](../README.md) covers the
basic pull-request check; these recipes assemble the other pieces — scheduled
runs, fork-safe triggers, merge gating, and consuming `updates-json`.

## Weekly report as a tracking issue

On runs without a pull request context, `open-tracking-issue: true` keeps a
single issue updated with the report and closes it automatically once
everything is up to date — no PR required.

```yaml
name: Weekly SPM dependency report
on:
  schedule:
    - cron: '0 6 * * 1'
  workflow_dispatch:

permissions:
  contents: read
  issues: write

jobs:
  spm-updates:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hbmartin/github-action-spm_version_updates@v1
        with:
          package-manifest-paths: Modules/Package.swift
          open-tracking-issue: true
```

The issue number and URL are available as the `tracking-issue-number` and
`tracking-issue-url` outputs.

## Checking pull requests from forks

Fork PRs get a read-only token, so commenting requires `pull_request_target`
— which means the manifests under check are untrusted input. Pin the
checkout to the PR head, drop credentials, and restrict lookup hosts:

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

Read the [security guide](security.md) before enabling this — it explains
what a malicious fork PR could otherwise do.

## Blocking merges on major updates

`fail-on: major` fails the job when a major semantic-version update exists —
after the outputs, step summary, annotations, and PR comment have all been
written, so the failure is explained where reviewers look. Make the check
required in branch protection to actually block the merge.

```yaml
- uses: hbmartin/github-action-spm_version_updates@v1
  with:
    xcode-project-path: MyApp.xcodeproj
    fail-on: major   # 'minor' also fails on minor; 'patch' fails on any semantic update
```

## Posting updates to Slack

`updates-json` is a machine-readable mirror of the report. Pipe it through
`jq` into anything — here, a Slack incoming webhook:

```yaml
- id: spm
  uses: hbmartin/github-action-spm_version_updates@v1
  with:
    package-manifest-paths: Modules/Package.swift

- name: Notify Slack
  if: steps.spm.outputs.updates-found != '0'
  env:
    UPDATES_JSON: ${{ steps.spm.outputs.updates-json }}
    SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}
  run: |
    payload="$(jq -n --argjson updates "$UPDATES_JSON" \
      '{text: ("📦 SPM updates available:\n" + ([$updates[]
          | "• " + (if .package and .available_version
                    then "\(.package): \(.current_version) → \(.available_version)"
                    else .message end)
        ] | join("\n")))}')"
    curl -sS -X POST -H 'Content-type: application/json' --data "$payload" "$SLACK_WEBHOOK_URL"
```

Every update object has a `message`; the structured fields are present "when
available", so the recipe falls back to `message` for anything unusual.

## Opening an automatic bump PR

In manifest mode, each update carries a ready-to-run `suggested_command`
(`swift package update <identity>`) and a `source` naming the manifest it
applies to. A scheduled job on a macOS runner (for the Swift toolchain) can
apply every in-constraint update and open one PR with the result.

Updates that also carry `suggested_requirement` need a manifest edit first
(the new version is outside the declared constraint), so the script below
skips them — they keep being reported until you bump the constraint.

```yaml
name: SPM auto-bump
on:
  schedule:
    - cron: '0 6 * * 1'
  workflow_dispatch:

permissions:
  contents: write
  pull-requests: write

jobs:
  bump:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4

      - id: spm
        uses: hbmartin/github-action-spm_version_updates@v1
        with:
          package-manifest-paths: Modules/Package.swift

      - name: Apply in-constraint updates
        if: steps.spm.outputs.updates-found != '0'
        env:
          UPDATES_JSON: ${{ steps.spm.outputs.updates-json }}
        run: |
          echo "$UPDATES_JSON" |
            jq -r '.[]
              | select(.suggested_command != null and .suggested_requirement == null)
              | [.source, .suggested_command] | @tsv' |
            sort -u |
            while IFS="$(printf '\t')" read -r source command; do
              (cd "$(dirname "$source")" && $command)
            done

      - uses: peter-evans/create-pull-request@v7
        with:
          branch: spm-version-bumps
          title: Bump Swift package dependencies
          commit-message: Bump Swift package dependencies
```

## Different settings per manifest in one job

Invoking the action twice lets each manifest group use its own options. Leave
`setup-ruby` enabled on the first invocation and disable it on later ones —
the runtime is already installed. Both invocations would otherwise manage the
same single PR comment, so disable commenting on all but one:

```yaml
- uses: hbmartin/github-action-spm_version_updates@v1
  with:
    package-manifest-paths: Modules/Package.swift

- uses: hbmartin/github-action-spm_version_updates@v1
  with:
    package-manifest-paths: BuildTools/Package.swift
    report-above-maximum: true
    comment: false        # the first invocation owns the PR comment
    setup-ruby: false     # runtime already installed by the first invocation
```

If both groups should share one comment and one set of options, pass both
paths to a single invocation instead — that's the default multi-manifest
setup from the README.
