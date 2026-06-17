# frozen_string_literal: true

# Formats structured update result records into legacy warning strings for specs.
class SpecUpdateMessages
  def initialize(result)
    @result = result
  end

  def to_a
    @result.updates.map { |record| SpecUpdateMessage.new(record).to_s }
  end
end

# Formats one structured update record into the legacy warning string.
class SpecUpdateMessage
  def initialize(record)
    @record = record
  end

  def to_s
    [@record.fetch("message"), source_line].compact.join("\n")
  end

  private

  def source_line
    source = @record["source"]
    "Source: #{source}" if source
  end
end
