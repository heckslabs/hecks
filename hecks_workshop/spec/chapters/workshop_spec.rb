require "spec_helper"
require "hecks/chapters/workshop"

RSpec.describe Hecks::Chapters::Workshop do
  subject(:domain) { described_class.definition }

  it "returns a Domain named Workshop" do
    expect(domain.name).to eq("Workshop")
  end

  it "includes key aggregates" do
    names = domain.aggregates.map(&:name)
    expect(names).to include("Workshop", "Playground", "WorkshopSession")
  end

  it "includes internals paragraph aggregates" do
    names = domain.aggregates.map(&:name)
    expect(names).to include(
      "MermaidBuilder", "EventSerializer", "ServiceSerializer",
      "PolicyFlowBuilder", "SketchSteps", "PlaySteps",
      "MessageNotUnderstood", "BluebookMode"
    )
  end

  it "has commands on Workshop" do
    agg = domain.aggregates.find { |a| a.name == "Workshop" }
    cmds = agg.commands.map(&:name)
    expect(cmds).to include("CreateSession", "AddAggregate")
  end

  it "has commands on Playground" do
    agg = domain.aggregates.find { |a| a.name == "Playground" }
    cmds = agg.commands.map(&:name)
    expect(cmds).to include("Execute", "Reset")
  end

  it "has at least 2 aggregates" do
    expect(domain.aggregates.size).to be >= 2
  end

  it "every aggregate has at least one command" do
    domain.aggregates.each do |agg|
      expect(agg.commands).not_to be_empty, "#{agg.name} has no commands"
    end
  end
end
