# frozen_string_literal: true

require "yaml"

# Guards against the classic composite-action failure mode: an input declared
# in action.yml but never wired into the run step's env, or an INPUT_* env var
# read by the Ruby action that no declared input produces.
RSpec.describe "action.yml wiring" do # rubocop:disable RSpec/DescribeClass
  let(:root) { File.expand_path("../..", __dir__) }
  let(:action) { YAML.load_file(File.join(root, "action.yml")) }
  let(:check_step) { action.fetch("runs").fetch("steps").find { |step| step["id"] == "check" } }
  let(:check_env) { check_step.fetch("env") }

  # github-token is intentionally wired as GITHUB_TOKEN rather than INPUT_GITHUB_TOKEN.
  let(:env_name_overrides) { { "github-token" => "GITHUB_TOKEN" } }

  def input_env_name(input_name)
    "INPUT_#{input_name.tr('-', '_').upcase}"
  end

  it "wires every declared input into the check step env", :aggregate_failures do
    action.fetch("inputs").each_key do |input_name|
      env_name = env_name_overrides.fetch(input_name) { input_env_name(input_name) }
      expect(check_env).to have_key(env_name), "input #{input_name} is not wired as env #{env_name} in the check step"
      expect(check_env.fetch(env_name, "")).to include("inputs.#{input_name}"),
                                               "env #{env_name} does not reference inputs.#{input_name}"
    end
  end

  it "declares an input for every INPUT_* env var the action reads" do
    declared = action.fetch("inputs").keys.map { |name| input_env_name(name) }
    read = Dir.glob(File.join(root, "lib/**/*.{rb,sh}"))
      .flat_map { |path| File.read(path).scan(/INPUT_[A-Z0-9_]+/) }
      .uniq

    expect(read - declared).to be_empty,
                               "INPUT_* env vars read but not declared in action.yml: #{(read - declared).join(', ')}"
  end

  it "maps every declared output to the check step" do
    action.fetch("outputs").each_value do |output|
      expect(output.fetch("value")).to include("steps.check.outputs.")
    end
  end
end
