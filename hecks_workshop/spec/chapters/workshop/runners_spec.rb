# Workshop::RunnersParagraph paragraph spec
#
# Verifies workshop runner aggregates exist within the Workshop domain.
#
require "spec_helper"
require "hecks/chapters/workshop"

RSpec.describe Hecks::Chapters::Workshop::RunnersParagraph do
  subject(:domain) { Hecks::Chapters::Workshop.definition }

  it "includes WorkshopRunner with Run command" do
    agg = domain.aggregates.find { |a| a.name == "WorkshopRunner" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Run")
  end

  it "includes ConstantHoister with HoistAggregate" do
    agg = domain.aggregates.find { |a| a.name == "ConstantHoister" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("HoistAggregate")
  end

  it "includes WebRunner with Run" do
    agg = domain.aggregates.find { |a| a.name == "WebRunner" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Run")
  end

  it "includes Evaluator and CommandParser" do
    names = domain.aggregates.map(&:name)
    expect(names).to include("Evaluator", "CommandParser")
  end

  it "includes StateSerializer" do
    agg = domain.aggregates.find { |a| a.name == "StateSerializer" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Serialize")
  end

  it "includes WorkshopSession with Execute and GetCompletions" do
    agg = domain.aggregates.find { |a| a.name == "WorkshopSession" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Execute", "GetCompletions")
  end
end
