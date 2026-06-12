# frozen_string_literal: true

require "reek/rake/task"
require "rspec/core/rake_task"
require "rubocop/rake_task"

RUBY_SOURCE_PATTERNS = [
  "action/lib/**/*.rb",
  "gems/*/lib/**/*.rb",
  "spec/**/*.rb",
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

desc "Ensure that the plugin passes `danger plugins lint`"
task :spec_docs do
  Dir.chdir("gems/danger-spm_version_updates") {
    sh({ "BUNDLE_GEMFILE" => File.expand_path("Gemfile", __dir__) }, "bundle exec danger plugins lint")
  }
end
