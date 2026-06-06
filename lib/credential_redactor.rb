# frozen_string_literal: true

# Redacts credentials embedded in URL userinfo before logging or emitting data.
module CredentialRedactor
  module_function

  def redact(value)
    value&.to_s&.gsub(%r{([a-z][a-z0-9+\-.]*://)([^/\s@]+)@}i, '\1[REDACTED]@')
  end

  def redact_hash_value(hash, key)
    hash.dup.tap { |copy|
      copy[key] = redact(copy[key]) if copy.key?(key)
    }
  end
end
