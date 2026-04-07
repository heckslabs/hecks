require "spec_helper"
require "hecks/chapters/bluebook"

RSpec.describe Hecks::Chapters::Bluebook::AstParagraph do
  subject(:domain) { Hecks::Chapters::Bluebook.definition }

  let(:names) { domain.aggregates.map(&:name) }

  it "includes AST and event storm aggregates" do
    expect(names).to include("AggregateVisitor", "DomainVisitor",
                             "EventStormImporter", "YamlParser")
  end

  it "AggregateVisitor has VisitAggregate command" do
    agg = domain.aggregates.find { |a| a.name == "AggregateVisitor" }
    expect(agg.commands.map(&:name)).to include("VisitAggregate")
  end

  it "EventStormImporter has ImportEventStorm command" do
    agg = domain.aggregates.find { |a| a.name == "EventStormImporter" }
    expect(agg.commands.map(&:name)).to include("ImportEventStorm")
  end

  it "contributes at least 9 AST/import aggregates" do
    ast_names = %w[AggregateVisitor DomainVisitor NodeReaders EventStormImporter
                   DslGenerator YamlParser Result
                   PatternMatching ContextGrouping]
    present = ast_names.select { |n| names.include?(n) }
    expect(present.size).to be >= 9
  end

  it "every AST aggregate has a description" do
    %w[AggregateVisitor DomainVisitor EventStormImporter YamlParser].each do |n|
      agg = domain.aggregates.find { |a| a.name == n }
      expect(agg.description).not_to be_nil, "#{n} missing description"
    end
  end
end
