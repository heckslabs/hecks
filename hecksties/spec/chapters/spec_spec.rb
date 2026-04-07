require "spec_helper"
require "hecks/chapters/spec"

RSpec.describe Hecks::Chapters::Spec do
  subject(:domain) { described_class.definition }

  it "returns a Domain named Spec" do
    expect(domain.name).to eq("Spec")
  end

  it "includes key aggregates" do
    names = domain.aggregates.map(&:name)
    expect(names).to include(
      "TestHelper", "InMemoryLoader", "MemoryAdapter",
      "MemoryOutbox", "EventBus", "InMemoryExecutor",
      "SpecGenerator", "SpecHelpers", "SpecWriter", "ServerHelpers"
    )
  end

  it "has commands on TestHelper" do
    agg = domain.aggregates.find { |a| a.name == "TestHelper" }
    expect(agg.commands.map(&:name)).to include("Reset")
  end

  it "has commands on EventBus" do
    agg = domain.aggregates.find { |a| a.name == "EventBus" }
    expect(agg.commands.map(&:name)).to include("Subscribe", "Publish", "Clear")
  end

  it "has commands on SpecGenerator" do
    agg = domain.aggregates.find { |a| a.name == "SpecGenerator" }
    expect(agg.commands.map(&:name)).to include("GenerateSpecHelper")
  end

  it "every aggregate has at least one command" do
    domain.aggregates.each do |agg|
      expect(agg.commands).not_to be_empty, "#{agg.name} has no commands"
    end
  end
end
