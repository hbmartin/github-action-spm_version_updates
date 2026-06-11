#!/usr/bin/env bash
# One-shot setup for the frozen e2e fixture repository.
#
# Creates https://github.com/hbmartin/spm-action-e2e-fixture with a fixed set
# of semver tags. The e2e workflow (.github/workflows/e2e.yml) asserts exact
# versions against this repo, so its tags must NEVER be added to, moved, or
# deleted after creation.
#
# Requires an authenticated `gh` CLI. Run once from anywhere:
#   bash script/setup_e2e_fixture_repo.sh
set -euo pipefail

repo="hbmartin/spm-action-e2e-fixture"
tags=(1.0.0 1.2.3 2.0.0-beta.1 2.0.0)

if gh repo view "$repo" > /dev/null 2>&1; then
  echo "Repository $repo already exists; refusing to touch it." >&2
  exit 1
fi

dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT

git -C "$dir" init -b main

cat > "$dir/Package.swift" <<'EOF'
// swift-tools-version:5.9
import PackageDescription

let package = Package(name: "SpmActionE2eFixture", products: [], targets: [])
EOF

cat > "$dir/README.md" <<'EOF'
# spm-action-e2e-fixture

Frozen fixture for the end-to-end tests of
[github-action-spm_version_updates](https://github.com/hbmartin/github-action-spm_version_updates).

The e2e workflow asserts exact results against this repository's tags:
`1.0.0`, `1.2.3`, `2.0.0-beta.1`, `2.0.0`.

**Do not add, move, or delete tags in this repository.**
EOF

git -C "$dir" add -A
git -C "$dir" commit -m "Frozen fixture package for spm version updates e2e tests"

for tag in "${tags[@]}"; do
  git -C "$dir" tag "$tag"
done

gh repo create "$repo" --public \
  --description "Frozen e2e fixture for github-action-spm_version_updates. Do not modify tags." \
  --source "$dir" --push

git -C "$dir" push origin --tags

echo "Created $repo with tags: ${tags[*]}"
