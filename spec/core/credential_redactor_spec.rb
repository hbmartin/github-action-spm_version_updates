# frozen_string_literal: true

require "spm_version_updates/credential_redactor"

RSpec.describe CredentialRedactor do
  describe ".redact" do
    it "preserves nil values" do
      expect(described_class.redact(nil)).to be_nil
    end

    it "redacts URL userinfo" do
      expect(described_class.redact("https://user:token@github.com/owner/repo"))
        .to eq("https://[REDACTED]@github.com/owner/repo")
    end
  end

  describe ".redact_hash_value" do
    it "does not mutate nil hash values into strings" do
      record = { "repository_url" => nil }

      expect(described_class.redact_hash_value(record, "repository_url"))
        .to eq("repository_url" => nil)
    end
  end
end
