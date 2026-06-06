# frozen_string_literal: true

source "https://rubygems.org"

# Core dependencies for GitHub Action
# Octokit/Danger configure Faraday retry middleware at runtime under Faraday v2.
gem "faraday-retry", "~> 2.4"
gem "octokit", "~> 8.0"
gem "semverify", "~> 0.3"

group(:xcode) {
  gem "xcodeproj", "~> 1.24"
}

# Development and test dependencies
group(:development, :test) {
  gem "danger", "~> 9.5"
  gem "guard"
  gem "guard-rspec"
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
