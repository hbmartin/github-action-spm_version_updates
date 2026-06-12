# frozen_string_literal: true

require "reek/rake/task"
require "rspec/core/rake_task"
require "rubocop/rake_task"

RUBY_SOURCE_PATTERNS = [
  "action/lib/**/*.rb",
  "gems/*/lib/**/*.rb",
  "spec/**/*.rb",
].freeze

DOCS_SITE_DIR = "_site"
DOCS_GUIDES = [
  "docs/architecture.md",
  "docs/migration-v0.2.0-to-v1.0.0.md",
  "docs/swiftpm-manifest-mode.md",
].freeze
DOCS_LAYERS = {
  "core" => {
    title: "spm_version_updates (core gem)",
    sources: ["gems/spm_version_updates/lib/**/*.rb"]
  },
  "danger" => {
    title: "danger-spm_version_updates (Danger plugin)",
    sources: ["gems/danger-spm_version_updates/lib/**/*.rb"]
  },
  "action" => {
    title: "spm_version_updates (GitHub Action runner)",
    sources: ["action/lib/**/*.rb"]
  }
}.freeze
# Documented-object floor enforced by docs:check; raise it as coverage improves.
DOCS_MINIMUM_COVERAGE = 54.0

VERSION_FILE = "gems/spm_version_updates/lib/spm_version_updates/version.rb"
# Every directory whose Gemfile.lock embeds the path-gem version and must be
# regenerated when it changes.
BUNDLE_DIRS = [
  ".",
  "action",
  "gems/spm_version_updates",
  "gems/danger-spm_version_updates",
].freeze
# gems/*/Gemfile.lock is gitignored (those bundles resolve at install time),
# so only these lockfiles are committed with the bump.
COMMITTED_LOCKFILES = [
  "Gemfile.lock",
  "action/Gemfile.lock",
].freeze

RSpec::Core::RakeTask.new(:specs)

task default: :specs

desc "Run all test and lint tasks"
task :spec do
  Rake::Task["specs"].invoke
  Rake::Task["rubocop"].invoke
  Rake::Task["reek"].invoke
  Rake::Task["spec_docs"].invoke
end

desc "Run RuboCop on the gems/action/spec directories"
RuboCop::RakeTask.new(:rubocop) { |task|
  task.requires << "rubocop-rspec"
  task.requires << "rubocop-rake"
  task.requires << "rubocop-performance"
  task.patterns = RUBY_SOURCE_PATTERNS
}

desc "Run Reek on the gems/action/spec directories"
Reek::Rake::Task.new(:reek) { |task|
  task.source_files = FileList[*RUBY_SOURCE_PATTERNS]
}

namespace :docs do
  DOCS_LAYERS.each do |layer, config|
    desc "Build the #{layer} layer documentation"
    # Each layer builds in its own process: YARD's in-memory registry is a
    # singleton, so sharing a process would leak objects across layers.
    task layer.to_sym do
      sh(
        "bundle",
        "exec",
        "yard",
        "doc",
        "--no-yardopts",
        "--output-dir",
        "#{DOCS_SITE_DIR}/#{layer}",
        "--db",
        ".yardoc-#{layer}",
        "--title",
        config[:title],
        "--main",
        "README.md",
        "--hide-api",
        "private",
        "--tag",
        "tags:Tags",
        *config[:sources],
        "-",
        "README.md",
        *DOCS_GUIDES
      )
    end
  end

  desc "Build the per-layer documentation site into #{DOCS_SITE_DIR}/"
  task build: DOCS_LAYERS.keys.map { |layer| "docs:#{layer}" } do
    cp("docs/pages/index.html", "#{DOCS_SITE_DIR}/index.html")
    touch("#{DOCS_SITE_DIR}/.nojekyll")
  end

  desc "Fail on YARD warnings, undocumented classes/modules, or coverage regressions"
  task :check do
    require "open3"

    output, status = Open3.capture2e("bundle", "exec", "yard", "stats", "--list-undoc")
    puts(output)
    abort("yard stats failed") unless status.success?
    abort("YARD emitted warnings; fix the doc comments above") if output.include?("[warn]")
    abort("Undocumented classes or modules found; document the items listed above") if output.match?(/^(Modules|Classes):.*[1-9]\d* undocumented/)
    coverage = output[/(\d+\.\d+)% documented/, 1].to_f
    abort("Documentation coverage #{coverage}% fell below the #{DOCS_MINIMUM_COVERAGE}% floor") if coverage < DOCS_MINIMUM_COVERAGE
  end
end

desc "Build the documentation site"
task docs: "docs:build"

desc "Bump the gem version, regenerate every Gemfile.lock, and commit + tag the release"
task :bump, [:version] do |_task, args|
  require "bundler"

  version = args[:version]
  abort("Usage: rake 'bump[X.Y.Z]'") unless version&.match?(/\A\d+\.\d+\.\d+\z/)
  abort("Working tree is dirty; commit or stash everything before bumping") unless `git status --porcelain`.empty?

  source = File.read(VERSION_FILE)
  current = source[/VERSION = "([^"]+)"/, 1]
  abort("Could not find the VERSION constant in #{VERSION_FILE}") unless current
  abort("New version #{version} must be greater than current #{current}") if Gem::Version.new(version) <= Gem::Version.new(current)

  File.write(VERSION_FILE, source.sub(/VERSION = "[^"]+"/, %(VERSION = "#{version}")))

  # The path gems pin each other's exact version, so every lockfile embeds it
  # and must be regenerated. Drop the root bundle's environment so each
  # directory resolves against its own Gemfile.
  Bundler.with_unbundled_env {
    BUNDLE_DIRS.each { |dir|
      Dir.chdir(dir) { sh("bundle", "install", "--quiet") }
    }
  }

  sh("git", "add", VERSION_FILE, *COMMITTED_LOCKFILES)
  sh("git", "commit", "-m", "Bump version to #{version}")
  sh("git", "tag", "v#{version}")

  puts <<~NEXT_STEPS

    Bumped #{current} -> #{version} and tagged v#{version}.

    Next steps (pushing the tag publishes the gems via push_gem.yml):
      git push origin HEAD v#{version}
    then publish a GitHub release for v#{version} to move the floating major tag.
  NEXT_STEPS
end

desc "Ensure that the plugin passes `danger plugins lint`"
task :spec_docs do
  Dir.chdir("gems/danger-spm_version_updates") {
    sh({ "BUNDLE_GEMFILE" => File.expand_path("Gemfile", __dir__) }, "bundle exec danger plugins lint")
  }
end
