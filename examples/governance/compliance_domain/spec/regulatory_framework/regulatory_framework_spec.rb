require_relative "../spec_helper"

RSpec.describe ComplianceDomain::RegulatoryFramework do
  describe "creating a RegulatoryFramework" do
    subject(:regulatory_framework) { described_class.new(
          name: "example",
          jurisdiction: "example",
          version: "example",
          effective_date: Date.today,
          authority: "example",
          requirements: [],
          status: "example"
        ) }

    it "assigns an id" do
      expect(regulatory_framework.id).not_to be_nil
    end

    it "sets name" do
      expect(regulatory_framework.name).to eq("example")
    end

    it "sets jurisdiction" do
      expect(regulatory_framework.jurisdiction).to eq("example")
    end

    it "sets version" do
      expect(regulatory_framework.version).to eq("example")
    end

    it "sets effective_date" do
      expect(regulatory_framework.effective_date).not_to be_nil
    end

    it "sets authority" do
      expect(regulatory_framework.authority).to eq("example")
    end

    it "sets requirements" do
      expect(regulatory_framework.requirements).to eq([])
    end

    it "sets status" do
      expect(regulatory_framework.status).to eq("example")
    end
  end

  describe "name validation" do
    it "rejects nil name" do
      expect {
        described_class.new(
          name: nil,
          jurisdiction: "example",
          version: "example",
          effective_date: Date.today,
          authority: "example",
          requirements: [],
          status: "example"
        )
      }.to raise_error(ComplianceDomain::ValidationError, /name/)
    end
  end

  describe "jurisdiction validation" do
    it "rejects nil jurisdiction" do
      expect {
        described_class.new(
          name: "example",
          jurisdiction: nil,
          version: "example",
          effective_date: Date.today,
          authority: "example",
          requirements: [],
          status: "example"
        )
      }.to raise_error(ComplianceDomain::ValidationError, /jurisdiction/)
    end
  end

  describe "identity" do
    it "two RegulatoryFrameworks with the same id are equal" do
      id = SecureRandom.uuid
      a = described_class.new(
          name: "example",
          jurisdiction: "example",
          version: "example",
          effective_date: Date.today,
          authority: "example",
          requirements: [],
          status: "example",
          id: id
        )
      b = described_class.new(
          name: "example",
          jurisdiction: "example",
          version: "example",
          effective_date: Date.today,
          authority: "example",
          requirements: [],
          status: "example",
          id: id
        )
      expect(a).to eq(b)
    end

    it "two RegulatoryFrameworks with different ids are not equal" do
      a = described_class.new(
          name: "example",
          jurisdiction: "example",
          version: "example",
          effective_date: Date.today,
          authority: "example",
          requirements: [],
          status: "example"
        )
      b = described_class.new(
          name: "example",
          jurisdiction: "example",
          version: "example",
          effective_date: Date.today,
          authority: "example",
          requirements: [],
          status: "example"
        )
      expect(a).not_to eq(b)
    end
  end
end
