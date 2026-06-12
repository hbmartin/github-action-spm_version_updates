# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Gem::Specification do
  def prepare_checkout_with_spaces(root)
    checkout = File.join(root, "repo with spaces")
    FileUtils.mkdir_p(checkout)
    FileUtils.cp_r(File.expand_path("../../gems", __dir__), checkout)

    expect_successful_git_commands(["init", checkout], ["-C", checkout, "add", "gems"])

    checkout
  end

  def expect_successful_git_commands(*commands)
    commands.each do |command|
      expect(system("git", *command, out: File::NULL, err: File::NULL)).to be(true)
    end
  end

  def load_spec_from(checkout, gem_name)
    without_warnings do
      Gem::Specification.load(File.join(checkout, "gems", gem_name, "#{gem_name}.gemspec"))
    end
  end

  def without_warnings
    previous_verbose = $VERBOSE
    $VERBOSE = nil
    yield
  ensure
    $VERBOSE = previous_verbose
  end

  it "uses git file lists when gem directories are inside paths with spaces" do
    Dir.mktmpdir("gemspec path with spaces") do |root|
      checkout = prepare_checkout_with_spaces(root)
      untracked_file = "lib/untracked fixture.rb"

      %w(danger-spm_version_updates spm_version_updates).each do |gem_name|
        FileUtils.touch(File.join(checkout, "gems", gem_name, untracked_file))

        expect(load_spec_from(checkout, gem_name).files)
          .not_to include(untracked_file)
      end
    end
  end
end
