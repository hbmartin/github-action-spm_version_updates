# frozen_string_literal: true

require "simplecov"
require "simplecov-cobertura"

SimpleCov.formatter = SimpleCov::Formatter::MultiFormatter.new(
  [
    SimpleCov::Formatter::HTMLFormatter,
    SimpleCov::Formatter::CoberturaFormatter,
  ]
)

SimpleCov.start do
  track_files "{action,gems/*}/lib/**/*.rb"
  add_filter "/spec/"

  minimum_coverage ENV.fetch("SIMPLECOV_MINIMUM_COVERAGE").to_f if ENV["SIMPLECOV_MINIMUM_COVERAGE"]
end
