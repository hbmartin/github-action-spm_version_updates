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

# Renders the README input/output tables from action.yml, between
# `<!-- <section>-table:begin -->` / `<!-- <section>-table:end -->` markers.
# `rake docs:tables` regenerates them; `rake docs:tables:check` fails CI when
# they drift. Descriptions are edited in action.yml, not in the README.
module ReadmeActionTables
  ACTION_DEFINITION_FILE = "action.yml"
  README_FILE = "README.md"
  HEADERS = {
    "inputs" => ["Input", "Description", "Default"],
    "outputs" => ["Output", "Description"]
  }.freeze

  def self.updated_readme
    require("yaml")

    action = YAML.safe_load_file(ACTION_DEFINITION_FILE)
    HEADERS.keys.reduce(File.read(README_FILE)) { |content, section|
      replace_section(content, section, table_for(section, action.fetch(section)))
    }
  end

  def self.table_for(section, entries)
    header = HEADERS.fetch(section)
    divider = header.map { |title| "-" * title.length }
    rows = entries.map { |name, spec| row_for(section, name, spec) }
    [row(header), row(divider), *rows].join("\n")
  end

  def self.row_for(section, name, spec)
    cells = ["`#{name}`", spec.fetch("description")]
    cells << default_cell(spec) if section == "inputs"
    row(cells)
  end

  def self.row(cells)
    "| #{cells.join(' | ')} |"
  end

  def self.default_cell(spec)
    default = spec.fetch("default", "").to_s
    default.empty? ? "" : "`#{default}`"
  end

  def self.replace_section(content, section, table)
    begin_marker = "<!-- #{section}-table:begin (generated from action.yml by `rake docs:tables`; edit descriptions there) -->"
    end_marker = "<!-- #{section}-table:end -->"
    pattern = /#{Regexp.escape(begin_marker)}\n.*?#{Regexp.escape(end_marker)}/m
    abort("#{README_FILE} is missing the #{section}-table:begin/end markers") unless content.match?(pattern)

    content.sub(pattern, "#{begin_marker}\n#{table}\n#{end_marker}")
  end
end
# Each layer opens on its own README and carries only the guides relevant to
# its audience; docs/architecture.md is shared because it explains the
# layering itself.
DOCS_LAYERS = {
  "core" => {
    title: "spm_version_updates (core gem)",
    sources: ["gems/spm_version_updates/lib/**/*.rb"],
    main: "gems/spm_version_updates/README.md",
    guides: [
      "docs/architecture.md",
      "docs/repo-rules.md",
      "docs/migration-v0.2.0-to-v1.0.0.md",
    ]
  },
  "danger" => {
    title: "danger-spm_version_updates (Danger plugin)",
    sources: ["gems/danger-spm_version_updates/lib/**/*.rb"],
    main: "gems/danger-spm_version_updates/README.md",
    guides: [
      "docs/architecture.md",
      "docs/swiftpm-manifest-mode.md",
      "docs/repo-rules.md",
      "docs/migration-v0.2.0-to-v1.0.0.md",
    ]
  },
  "action" => {
    title: "spm_version_updates (GitHub Action runner)",
    sources: ["action/lib/**/*.rb"],
    main: "README.md",
    guides: [
      "docs/architecture.md",
      "docs/swiftpm-manifest-mode.md",
      "docs/cookbook.md",
      "docs/security.md",
      "docs/troubleshooting.md",
      "docs/repo-rules.md",
    ]
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
  Rake::Task["docs:tables:check"].invoke
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
        # The custom template reads the layer name to render the cross-layer
        # banner with the right links and active item.
        { "SPM_DOCS_LAYER" => layer },
        "bundle",
        "exec",
        "yard",
        "doc",
        "--no-yardopts",
        "--output-dir",
        "#{DOCS_SITE_DIR}/#{layer}",
        "--db",
        ".yardoc-#{layer}",
        "--template-path",
        "templates",
        "--title",
        config[:title],
        "--main",
        config[:main],
        "--hide-api",
        "private",
        "--tag",
        "tags:Tags",
        *config[:sources],
        "-",
        config[:main],
        *config[:guides]
      )
    end
  end

  desc "Build the per-layer documentation site into #{DOCS_SITE_DIR}/"
  task build: DOCS_LAYERS.keys.map { |layer| "docs:#{layer}" } do
    cp("docs/pages/index.html", "#{DOCS_SITE_DIR}/index.html")
    cp("docs/pages/favicon.svg", "#{DOCS_SITE_DIR}/favicon.svg")
    touch("#{DOCS_SITE_DIR}/.nojekyll")
  end

  desc "Regenerate the README input/output tables from action.yml"
  task :tables do
    File.write(ReadmeActionTables::README_FILE, ReadmeActionTables.updated_readme)
  end

  namespace :tables do
    desc "Fail when the README input/output tables are out of sync with action.yml"
    task :check do
      next if File.read(ReadmeActionTables::README_FILE) == ReadmeActionTables.updated_readme

      abort("README.md input/output tables are out of sync with action.yml; run `bundle exec rake docs:tables`")
    end
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
