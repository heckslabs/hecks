require "spec_helper"
require "hecks/chapters/hecksagon"

RSpec.describe Hecks::Chapters::Hecksagon do
  subject(:domain) { described_class.definition }

  it "returns a Domain named Hecksagon" do
    expect(domain.name).to eq("Hecksagon")
  end

  it "includes key aggregates" do
    names = domain.aggregates.map(&:name)
    expect(names).to include("GateDefinition", "HecksagonBuilder", "AclDefinition")
  end

  it "has commands on GateDefinition" do
    agg = domain.aggregates.find { |a| a.name == "GateDefinition" }
    expect(agg.commands.map(&:name)).to include("Create")
  end

  it "has commands on HecksagonBuilder" do
    agg = domain.aggregates.find { |a| a.name == "HecksagonBuilder" }
    expect(agg.commands).not_to be_empty
  end

  it "has at least 2 aggregates" do
    expect(domain.aggregates.size).to be >= 2
  end

  it "every aggregate has at least one command" do
    domain.aggregates.each do |agg|
      expect(agg.commands).not_to be_empty, "#{agg.name} has no commands"
    end
  end

  it "every aggregate has a description" do
    domain.aggregates.each do |agg|
      expect(agg.description).not_to be_nil, "#{agg.name} missing description"
    end
  end

  it "includes capabilities paragraph aggregates" do
    names = domain.aggregates.map(&:name)
    expect(names).to include(
      "AggregateCapabilityBuilder", "AttributeSelector",
      "TagApplier", "HecksagonModule"
    )
  end
end
