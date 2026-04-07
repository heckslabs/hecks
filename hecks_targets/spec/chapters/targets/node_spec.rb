# Targets::Node paragraph spec
#
# Verifies Node paragraph aggregates exist within the Targets domain.
#
require "spec_helper"
require "hecks/chapters/targets"

RSpec.describe Hecks::Chapters::Targets::Node do
  subject(:domain) { Hecks::Chapters::Targets.definition }

  it "includes NodeUtils with TsType and CamelCase commands" do
    agg = domain.aggregates.find { |a| a.name == "NodeUtils" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("TsType", "CamelCase")
  end

  it "includes NodeAggregateGenerator" do
    agg = domain.aggregates.find { |a| a.name == "NodeAggregateGenerator" }
    expect(agg).not_to be_nil
  end

  it "includes NodeServerGenerator" do
    agg = domain.aggregates.find { |a| a.name == "NodeServerGenerator" }
    expect(agg).not_to be_nil
  end

  it "includes NodeProjectGenerator" do
    agg = domain.aggregates.find { |a| a.name == "NodeProjectGenerator" }
    expect(agg).not_to be_nil
  end

  it "includes at least 7 Node aggregates" do
    node_aggs = domain.aggregates.select { |a| a.name.start_with?("Node") }
    expect(node_aggs.size).to be >= 7
  end
end
