# frozen_string_literal: true

require "tmpdir"

load(File.expand_path("../../Rakefile", __dir__))

RSpec.describe ReadmeActionTables do
  def readme_with_markers
    <<~MARKDOWN
      # Example

      <!-- inputs-table:begin (generated from action.yml by `rake docs:tables`; edit descriptions there) -->
      old inputs
      <!-- inputs-table:end -->

      <!-- outputs-table:begin (generated from action.yml by `rake docs:tables`; edit descriptions there) -->
      old outputs
      <!-- outputs-table:end -->
    MARKDOWN
  end

  def render_readme(action_yaml)
    Dir.mktmpdir("readme-action-tables") do |dir|
      action_file, readme_file = write_readme_files(dir, action_yaml)

      stub_readme_files(action_file, readme_file)
      described_class.updated_readme
    end
  end

  def write_readme_files(dir, action_yaml)
    action_file = File.join(dir, "action.yml")
    readme_file = File.join(dir, "README.md")
    File.write(action_file, action_yaml)
    File.write(readme_file, readme_with_markers)
    [action_file, readme_file]
  end

  def stub_readme_files(action_file, readme_file)
    stub_const("#{described_class}::ACTION_DEFINITION_FILE", action_file)
    stub_const("#{described_class}::README_FILE", readme_file)
  end

  it "renders empty generated tables when action.yml omits inputs and outputs", :aggregate_failures do
    readme = render_readme(<<~YAML)
      name: Test Action
    YAML

    expect(readme).to include("| Input | Description | Default |\n| ----- | ----------- | ------- |")
    expect(readme).to include("| Output | Description |\n| ------ | ----------- |")
  end

  it "renders empty generated tables when action.yml sections parse as nil", :aggregate_failures do
    readme = render_readme(<<~YAML)
      inputs:
      outputs:
    YAML

    expect(readme).to include("| Input | Description | Default |\n| ----- | ----------- | ------- |")
    expect(readme).to include("| Output | Description |\n| ------ | ----------- |")
  end

  it "escapes table-breaking characters in descriptions" do
    row = described_class.table_for(
      "outputs",
      {
        "result" => {
          "description" => "first | second\nthird"
        }
      }
    )

    expect(row).to include("| `result` | first \\| second third |")
  end

  it "escapes table-breaking characters in default values" do
    row = described_class.table_for(
      "inputs",
      {
        "filter" => {
          "description" => "A filter expression",
          "default" => "a|b"
        }
      }
    )

    expect(row).to include("| `filter` | A filter expression | `a\\|b` |")
  end
end
