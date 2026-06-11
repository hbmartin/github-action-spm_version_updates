# frozen_string_literal: true

# Compatibility shim: the version constant now lives in the spm_version_updates
# core gem. Existing `require "spm_version_updates/gem_version"` callers keep
# working through this file.
require "spm_version_updates/version"
