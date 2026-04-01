require "spec_helper"

RSpec.describe Hecks::Conventions::CsrfContract do
  describe "constants" do
    it { expect(described_class::COOKIE_NAME).to eq("_csrf_token") }
    it { expect(described_class::FIELD_NAME).to eq("_csrf_token") }
    it { expect(described_class::TOKEN_LENGTH).to eq(32) }
  end

  describe ".generate_token" do
    it "returns a 64-character hex string" do
      expect(described_class.generate_token).to match(/\A[0-9a-f]{64}\z/)
    end

    it "returns a different token each call" do
      expect(described_class.generate_token).not_to eq(described_class.generate_token)
    end
  end

  describe ".cookie_header" do
    it "includes the token and SameSite=Strict; HttpOnly" do
      header = described_class.cookie_header("abc123")
      expect(header).to eq("_csrf_token=abc123; SameSite=Strict; HttpOnly")
    end
  end

  describe ".valid?" do
    it "returns true when cookie and form values match" do
      expect(described_class.valid?("token123", "token123")).to be true
    end

    it "returns false when values differ" do
      expect(described_class.valid?("token123", "other")).to be false
    end

    it "returns false when cookie is nil" do
      expect(described_class.valid?(nil, "token123")).to be false
    end

    it "returns false when form value is nil" do
      expect(described_class.valid?("token123", nil)).to be false
    end

    it "returns false when either is empty string" do
      expect(described_class.valid?("", "token123")).to be false
      expect(described_class.valid?("token123", "")).to be false
    end
  end
end
