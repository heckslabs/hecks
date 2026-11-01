require "spec_helper"
require_relative "support/registry_double"

# The shared registry for specs of readers answers as an empty real registry does.
RSpec.describe RegistryDouble do
  include described_class

  it "answers nil for a world it does not hold" do
    expect(registry_double.world("Tickets")).to be_nil
  end

  it "answers the stubbed messages", :aggregate_failures do
    registry = registry_double(first_domain_name: "Shop")

    expect(registry.first_domain_name).to eq("Shop")
    expect(registry.bluebooks).to eq({})
  end

  it "keeps its answer for arguments a narrower stub does not name" do
    registry = registry_double
    allow(registry).to receive(:binding_settings).with("Shop", "persisted_by", "Sqlite").and_return({ a: 1 })

    expect(registry.binding_settings("Shop", "persisted_by", "Other")).to eq({})
  end
end
