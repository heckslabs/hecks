# Targets::Go paragraph spec
#
# Verifies Go paragraph aggregates exist within the Targets domain.
#
require "spec_helper"
require "hecks/chapters/targets"

RSpec.describe Hecks::Chapters::Targets::Go do
  subject(:domain) { Hecks::Chapters::Targets.definition }

  it "includes GoCodeBuilder with Struct and Render commands" do
    agg = domain.aggregates.find { |a| a.name == "GoCodeBuilder" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Struct", "Render")
  end

  it "includes GoUtils with GoType and PascalCase commands" do
    agg = domain.aggregates.find { |a| a.name == "GoUtils" }
    expect(agg.commands.map(&:name)).to include("GoType", "PascalCase")
  end

  it "includes GoProjectGenerator" do
    agg = domain.aggregates.find { |a| a.name == "GoProjectGenerator" }
    expect(agg).not_to be_nil
  end

  it "includes GoServerGenerator" do
    agg = domain.aggregates.find { |a| a.name == "GoServerGenerator" }
    expect(agg).not_to be_nil
  end

  it "includes GoRuntimeGenerator with event and command bus commands" do
    agg = domain.aggregates.find { |a| a.name == "GoRuntimeGenerator" }
    expect(agg.commands.map(&:name)).to include("GenerateEventBus", "GenerateCommandBus")
  end
end
