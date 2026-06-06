# frozen_string_literal: true

require "open3"
require "shellwords"
require "tmpdir"

# Test target descriptor for the shell runtime preflight.
module ActionRuntimePreflight
  SCRIPT = File.expand_path("../../lib/action_runtime_preflight.sh", __dir__)
end

RSpec.describe ActionRuntimePreflight do
  let(:script) { described_class::SCRIPT }
  let(:stub_command) {
    lambda { |bin, name, exit_status:, output: nil|
      path = File.join(bin, name)
      File.write(
        path,
        <<~SCRIPT
          #!/bin/bash
          #{output ? "echo #{Shellwords.escape(output)}" : ''}
          exit #{exit_status}
        SCRIPT
      )
      File.chmod(0o755, path)
    }
  }

  it "does not require Ruby or Bundler when setup-ruby is enabled", :aggregate_failures do
    Dir.mktmpdir("preflight-empty-path") do |empty_path|
      stdout, stderr, status = Open3.capture3({ "INPUT_SETUP_RUBY" => "true", "PATH" => empty_path }, "/bin/bash", script)

      expect(status).to be_success
      expect(stdout).to eq("")
      expect(stderr).to eq("")
    end
  end

  it "fails clearly when setup-ruby is disabled and Ruby is missing", :aggregate_failures do
    Dir.mktmpdir("preflight-empty-path") do |empty_path|
      stdout, stderr, status = Open3.capture3({ "INPUT_SETUP_RUBY" => "false", "PATH" => empty_path }, "/bin/bash", script)

      expect(status).not_to be_success
      expect(stdout).to include("setup-ruby is false, but ruby is not available on PATH")
      expect(stderr).to eq("")
    end
  end

  it "fails clearly when setup-ruby is disabled and Bundler is missing", :aggregate_failures do
    Dir.mktmpdir("preflight-bin") do |bin|
      stub_command.call(bin, "ruby", exit_status: 0)

      stdout, stderr, status = Open3.capture3({ "INPUT_SETUP_RUBY" => "false", "PATH" => bin }, "/bin/bash", script)

      expect(status).not_to be_success
      expect(stdout).to include("setup-ruby is false, but bundle is not available on PATH")
      expect(stderr).to eq("")
    end
  end

  it "fails clearly when setup-ruby is disabled and bundle check fails", :aggregate_failures do
    Dir.mktmpdir("preflight-bin") do |bin|
      stub_command.call(bin, "ruby", exit_status: 0)
      stub_command.call(bin, "bundle", exit_status: 1, output: "The following gems are missing")

      stdout, stderr, status = Open3.capture3(
        {
          "BUNDLE_WITHOUT" => "development:test:xcode",
          "INPUT_SETUP_RUBY" => "false",
          "PATH" => bin
        },
        "/bin/bash",
        script
      )

      expect(status).not_to be_success
      expect(stdout).to include("this action's bundle is not installed for BUNDLE_WITHOUT=development:test:xcode")
      expect(stdout).to include("The following gems are missing")
      expect(stderr).to eq("")
    end
  end
end
