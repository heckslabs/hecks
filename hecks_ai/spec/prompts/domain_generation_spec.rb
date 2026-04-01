require "spec_helper"

RSpec.describe Hecks::AI::Prompts::DomainGeneration do
  describe "SYSTEM_PROMPT" do
    it "contains DDD role definition" do
      expect(described_class::SYSTEM_PROMPT).to include("Domain-Driven Design")
    end

    it "includes Pizzas few-shot example" do
      expect(described_class::SYSTEM_PROMPT).to include("Pizzas")
    end

    it "includes Banking few-shot example" do
      expect(described_class::SYSTEM_PROMPT).to include("Banking")
    end

    it "mentions reference_to type" do
      expect(described_class::SYSTEM_PROMPT).to include("reference_to")
    end
  end

  describe "TOOL_SCHEMA" do
    subject(:schema) { described_class::TOOL_SCHEMA }

    it "is named define_domain" do
      expect(schema[:name]).to eq("define_domain")
    end

    it "requires domain_name and aggregates" do
      required = schema[:input_schema][:required]
      expect(required).to include("domain_name", "aggregates")
    end
  end
end
