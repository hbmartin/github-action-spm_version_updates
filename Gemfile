# frozen_string_literal: true

source "https://rubygems.org"

# Aggregate development bundle for the whole repository: both gems are
# resolved from their in-repo directories, alongside the GitHub Action's
# runtime dependencies (mirrored in action/Gemfile) and the dev tooling.
gemspec path: "gems/spm_version_updates", name: "spm_version_updates"
gemspec path: "gems/danger-spm_version_updates", name: "danger-spm_version_updates"

# GitHub Action runtime dependencies.
# Octokit/Danger configure Faraday retry middleware at runtime under Faraday v2.
gem "faraday-retry", "~> 2.4"
gem "octokit", "~> 10.0"

group(:xcode) {
  gem "xcodeproj", "~> 1.24"
}

# Development and test dependencies
group(:development, :test) {
  gem "danger", "~> 9.5"
  gem "guard"
  gem "guard-rspec"
  gem "guard-rubocop"
  gem "pry"
  gem "rake", "~> 13.2"
  gem "reek"
  gem "rspec", "~> 3.0"
  gem "rubocop", "~> 1.63"
  gem "rubocop-performance"
  gem "rubocop-rake"
  gem "rubocop-rspec"
  gem "simplecov", "~> 0.22"
  gem "simplecov-cobertura", "~> 3.1"
  gem "yard", "~> 0.9.36"
}
