# frozen_string_literal: true

lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require "spm_version_updates/version"

Gem::Specification.new do |spec|
  spec.name          = "spm_version_updates"
  spec.version       = SpmVersionUpdates::VERSION
  spec.authors       = ["Harold Martin"]
  spec.email         = ["harold.martin@gmail.com"]
  spec.description   = "Detect available updates to Swift Package Manager dependencies " \
                       "from Package.swift manifests or Xcode projects."
  spec.summary       = "Core library for checking Swift Package Manager dependency updates."
  spec.homepage      = "https://github.com/hbmartin/danger-spm_version_updates"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.2"

  release_paths = [
    "LICENSE.txt",
    "README.md",
    "spm_version_updates.gemspec",
  ]
  git_files = begin
    `git ls-files -z lib #{release_paths.join(" ")} 2>/dev/null`
      .split("\x0")
      .reject(&:empty?)
  rescue Errno::ENOENT
    []
  end
  fallback_files = Dir.glob(["lib/**/*", *release_paths])
    .select { |path| File.file?(path) }
  spec.files         = (git_files.empty? ? fallback_files : git_files).sort
  spec.require_paths = ["lib"]
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.add_runtime_dependency("semverify", "~> 0.3")
  # Xcode-project mode additionally requires the "xcodeproj" gem (loaded
  # lazily); manifest mode works without it.
end
