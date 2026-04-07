# Workshop::InternalsParagraph paragraph spec
#
# Verifies workshop internal aggregates exist within the Workshop domain.
#
require "spec_helper"
require "hecks/chapters/workshop"

RSpec.describe Hecks::Chapters::Workshop::InternalsParagraph do
  subject(:domain) { Hecks::Chapters::Workshop.definition }

  it "includes MermaidBuilder with Build command" do
    agg = domain.aggregates.find { |a| a.name == "MermaidBuilder" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Build")
  end

  it "includes EventSerializer and ServiceSerializer" do
    names = domain.aggregates.map(&:name)
    expect(names).to include("EventSerializer", "ServiceSerializer")
  end

  it "includes PolicyFlowBuilder" do
    agg = domain.aggregates.find { |a| a.name == "PolicyFlowBuilder" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Build")
  end

  it "includes SketchSteps and PlaySteps" do
    names = domain.aggregates.map(&:name)
    expect(names).to include("SketchSteps", "PlaySteps")
  end

  it "includes MessageNotUnderstood with HandleMissing" do
    agg = domain.aggregates.find { |a| a.name == "MessageNotUnderstood" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("HandleMissing")
  end

  it "includes BluebookMode with AddChapter and ToBluebook" do
    agg = domain.aggregates.find { |a| a.name == "BluebookMode" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("AddChapter", "ToBluebook")
  end
end
