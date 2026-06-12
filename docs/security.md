# Security guide

How the action touches the network and your tokens, what pull requests from
forks can and cannot do, and how to lock down runs on untrusted input.

## What the action actually does

- Reads dependency URLs from your `.xcodeproj` or `Package.swift` manifests in
  the checked-out workspace.
- Contacts each dependency's git host with `git ls-remote` to list version
  tags and branch heads. The GitHub token is **not** used for these lookups.
- Uses `github-token` (default: the job's automatic `${{ github.token }}`)
  only to post, update, or delete the PR comment and — with
  `open-tracking-issue: true` — the tracking issue.

URLs with embedded credentials are redacted before they appear in logs,
outputs, or the PR comment.

## Threat model: pull requests from forks

On your own branches, contacting the hosts named in your manifests is routine.
A pull request from a fork, however, can rewrite those URLs, so treat fork
runs as untrusted:

- **Fork PRs get a read-only `GITHUB_TOKEN`**, so the comment step can't
  write. To run on fork PRs, trigger with `pull_request_target` (review the
  [security implications](https://securitylab.github.com/resources/github-actions-preventing-pwn-requests/))
  or post the results from a separate, trusted workflow.
- **Fork PR manifests are untrusted input.** With `pull_request_target`,
  checking out the PR head lets a fork change `Package.swift` or `.xcodeproj`
  dependency URLs. Because lookups use `git ls-remote`, a malicious PR could
  point the runner at hosts it can reach and at credentials already available
  to git.

## Transport restrictions

Version lookups run git non-interactively (`GIT_TERMINAL_PROMPT=0`, so a
credential prompt fails instead of hanging) and limit it to the `https`,
`ssh`, and `git` transports via `GIT_ALLOW_PROTOCOL`. The `file` and `ext`
transports and remote helpers are blocked, so a manifest URL cannot read local
files or execute helper programs on the runner. Lookups are retried a bounded
number of times and then fail the run — an unreachable dependency is never
silently treated as "no updates".

## Restricting hosts with `allow-hosts`

`allow-hosts` is the main control for untrusted runs: it limits which hosts
`git ls-remote` may contact at all.

```yaml
with:
  package-manifest-paths: Modules/Package.swift
  allow-hosts: github.com,gitlab.example.com
```

Matching semantics:

- Hostnames match **exactly** and case-insensitively — `github.com` does not
  allow `evil-github.com` or `sub.github.com`.
- Schemes, credentials, paths, and ports are ignored, so
  `https://github.com/foo/bar`, `git@github.com:foo/bar.git`, and
  `ssh://git@github.com:2222/foo/bar` all match `github.com`.
- An empty `allow-hosts` (the default) allows any host reachable over the
  allowed transports.

When a dependency's host is not on the list, the action **fails before
contacting git** and writes `blocked=true` plus a descriptive
`error-message` output naming the dependency and host.

## Hardened fork-PR workflow

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

## Checklist for untrusted runs

- [ ] Check out the PR head with `persist-credentials: false` so the
      workflow's token is not left in the git credential store.
- [ ] Set `allow-hosts` to the host(s) your real dependencies live on.
- [ ] Don't expose extra secrets, SSH keys, or private-network access to the
      job — anything git can already authenticate with, a rewritten manifest
      URL can point at.
- [ ] Keep `permissions` minimal: `contents: read` plus `pull-requests: write`
      (and `issues: write` only with `open-tracking-issue: true`).
