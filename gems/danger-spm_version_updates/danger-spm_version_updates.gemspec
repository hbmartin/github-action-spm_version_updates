# frozen_string_literal: true

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

  spec.add_runtime_dependency("danger-plugin-api", "~> 1.0")
  spec.add_runtime_dependency("spm_version_updates", "~> #{SpmVersionUpdates::VERSION.split(".").first(2).join(".")}")
  spec.add_runtime_dependency("xcodeproj", "~> 1.24")
end
