require "spec_helper"

RSpec.describe Hecks::GovernanceGuard::Result do
  describe "#passed?" do
    it "returns true when no violations" do
      result = described_class.new
      expect(result.passed?).to be true
    end

    it "returns false when violations present" do
      result = described_class.new(violations: [{ concern: :privacy, message: "PII exposed" }])
      expect(result.passed?).to be false
    end
  end

  describe "#to_h" do
    it "returns a structured hash" do
      result = described_class.new(
        violations: [{ concern: :privacy, message: "PII exposed" }],
        suggestions: ["Fix it"]
      )

      hash = result.to_h
      expect(hash[:passed]).to be false
      expect(hash[:violations].size).to eq(1)
      expect(hash[:suggestions]).to eq(["Fix it"])
    end
  end

  describe "immutability" do
    it "freezes violations and suggestions" do
      result = described_class.new(
        violations: [{ concern: :privacy, message: "test" }],
        suggestions: ["suggestion"]
      )
      expect(result.violations).to be_frozen
      expect(result.suggestions).to be_frozen
    end
  end
end
