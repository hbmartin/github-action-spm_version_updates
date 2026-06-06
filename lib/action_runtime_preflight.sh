#!/usr/bin/env bash
set -euo pipefail

if [[ "${INPUT_SETUP_RUBY:-true}" != "false" ]]; then
  exit 0
fi

if ! command -v ruby >/dev/null 2>&1; then
  echo "::error::setup-ruby is false, but ruby is not available on PATH. Run this action once with setup-ruby: true earlier in the job, or leave setup-ruby enabled."
  exit 1
fi

if ! command -v bundle >/dev/null 2>&1; then
  echo "::error::setup-ruby is false, but bundle is not available on PATH. Run this action once with setup-ruby: true earlier in the job, or leave setup-ruby enabled."
  exit 1
fi

if ! bundle check >/dev/null 2>&1; then
  echo "::error::setup-ruby is false, but this action's bundle is not installed for BUNDLE_WITHOUT=${BUNDLE_WITHOUT:-unset}. Run an earlier invocation with setup-ruby: true using the same or a superset dependency mode."
  bundle check || true
  exit 1
fi
