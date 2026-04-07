require "spec_helper"
require "hecks/chapters/bluebook"

RSpec.describe Hecks::Chapters::Bluebook::StructureParagraph do
  subject(:domain) { Hecks::Chapters::Bluebook.definition }

  let(:names) { domain.aggregates.map(&:name) }

  it "includes structure IR aggregates" do
    expect(names).to include("Attribute", "Entity", "ValueObject", "Reference", "Lifecycle")
  end

  it "includes BluebookStructure root aggregate" do
    expect(names).to include("BluebookStructure")
  end

  it "Attribute aggregate has DefineAttribute command" do
    agg = domain.aggregates.find { |a| a.name == "Attribute" }
    expect(agg.commands.map(&:name)).to include("DefineAttribute")
  end

  it "contributes at least 14 structure aggregates" do
    structure_names = %w[BluebookStructure Actor Attribute ComputedAttribute Entity
                         ExternalSystem Invariant Lifecycle ReadModel Reference
                         Scope StateTransition ValidationNode ValueObject]
    present = structure_names.select { |n| names.include?(n) }
    expect(present.size).to be >= 14
  end

  it "every structure aggregate has a description" do
    structure_names = %w[BluebookStructure Actor Attribute Entity ValueObject]
    structure_names.each do |n|
      agg = domain.aggregates.find { |a| a.name == n }
      expect(agg.description).not_to be_nil, "#{n} missing description"
    end
  end
end
