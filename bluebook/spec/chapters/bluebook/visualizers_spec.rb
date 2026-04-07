require "spec_helper"
require "hecks/chapters/bluebook"

RSpec.describe Hecks::Chapters::Bluebook::VisualizersParagraph do
  subject(:domain) { Hecks::Chapters::Bluebook.definition }

  let(:names) { domain.aggregates.map(&:name) }

  it "includes visualizer aggregates" do
    expect(names).to include("DomainVisualizer", "BehaviorDiagram",
                             "PortDiagram", "StructureDiagram")
  end

  it "DomainVisualizer has VisualizeDomain command" do
    agg = domain.aggregates.find { |a| a.name == "DomainVisualizer" }
    expect(agg.commands.map(&:name)).to include("VisualizeDomain")
  end

  it "contributes at least 5 visualizer aggregates" do
    viz_names = %w[DomainVisualizer DomainVisualizerMethods BehaviorDiagram
                   PortDiagram StructureDiagram]
    present = viz_names.select { |n| names.include?(n) }
    expect(present.size).to be >= 5
  end

  it "every visualizer aggregate has a description" do
    %w[DomainVisualizer BehaviorDiagram PortDiagram StructureDiagram].each do |n|
      agg = domain.aggregates.find { |a| a.name == n }
      expect(agg.description).not_to be_nil, "#{n} missing description"
    end
  end
end
