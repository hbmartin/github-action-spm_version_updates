# frozen_string_literal: true

# This sibling-directory require only resolves inside the repository checkout.
# `gem build` serializes the literal version into the packaged metadata, so
# the shipped .gemspec is not meant to be evaluated standalone.
require_relative "../spm_version_updates/lib/spm_version_updates/version"

Gem::Specification.new do |spec|
  spec.name          = "danger-spm_version_updates"
  spec.version       = SpmVersionUpdates::VERSION
  spec.authors       = ["Harold Martin"]
  spec.email         = ["harold.martin@gmail.com"]
  spec.description   = "A Danger plugin to detect if there are any updates to your Swift Package Manager dependencies."
  spec.summary       = "A Danger plugin to detect if there are any updates to your Swift Package Manager dependencies."
  spec.homepage      = "https://github.com/hbmartin/danger-spm_version_updates"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.2"

  release_paths = [
    "LICENSE.txt",
    "README.md",
    "danger-spm_version_updates.gemspec",
  ]
  spec.files = Dir.chdir(__dir__) do
    git_files = begin
      `git ls-files -z lib #{release_paths.join(" ")} 2>/dev/null`
        .split("\x0")
        .reject(&:empty?)
    rescue Errno::ENOENT
      []
    end
    fallback_files = Dir.glob(["lib/**/*", *release_paths])
      .select { |path| File.file?(path) }
    (git_files.empty? ? fallback_files : git_files).sort
  end
  spec.require_paths = ["lib"]
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.add_runtime_dependency("danger-plugin-api", "~> 1.0")
  spec.add_runtime_dependency("spm_version_updates", "~> #{SpmVersionUpdates::VERSION}")
  spec.add_runtime_dependency("xcodeproj", "~> 1.24")
end
