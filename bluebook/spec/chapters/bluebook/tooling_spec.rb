require "spec_helper"
require "hecks/chapters/bluebook"

RSpec.describe Hecks::Chapters::Bluebook::ToolingParagraph do
  subject(:domain) { Hecks::Chapters::Bluebook.definition }

  let(:names) { domain.aggregates.map(&:name) }

  it "includes tooling aggregates" do
    expect(names).to include("DomainCompiler", "InMemoryLoader", "DomainInspector")
  end

  it "DomainCompiler has Compile and LoadDomain commands" do
    agg = domain.aggregates.find { |a| a.name == "DomainCompiler" }
    cmds = agg.commands.map(&:name)
    expect(cmds).to include("Compile", "LoadDomain")
  end

  it "SliceExtractor has ExtractSlices command" do
    agg = domain.aggregates.find { |a| a.name == "SliceExtractor" }
    expect(agg.commands.map(&:name)).to include("ExtractSlices")
  end

  it "contributes at least 5 tooling aggregates" do
    tooling = %w[DomainCompiler InMemoryLoader DomainInspector SliceDiagram SliceExtractor]
    present = tooling.select { |n| names.include?(n) }
    expect(present.size).to be >= 5
  end

  it "every tooling aggregate has a description" do
    %w[DomainCompiler InMemoryLoader DomainInspector].each do |n|
      agg = domain.aggregates.find { |a| a.name == n }
      expect(agg.description).not_to be_nil, "#{n} missing description"
    end
  end
end
