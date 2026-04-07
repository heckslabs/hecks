require "spec_helper"
require "hecks/chapters/bluebook"

RSpec.describe Hecks::Chapters::Bluebook::SpecGeneratorsParagraph do
  subject(:domain) { Hecks::Chapters::Bluebook.definition }

  let(:names) { domain.aggregates.map(&:name) }

  it "includes spec generator aggregates" do
    expect(names).to include("AggregateSpec", "CommandSpec",
                             "EventSpec", "PolicySpec")
  end

  it "AggregateSpec has GenerateAggregateSpec command" do
    agg = domain.aggregates.find { |a| a.name == "AggregateSpec" }
    expect(agg.commands.map(&:name)).to include("GenerateAggregateSpec")
  end

  it "contributes at least 14 spec generator aggregates" do
    spec_names = %w[AggregateSpec CommandSpec EntitySpec
                    EventSpec LifecycleSpec PolicySpec
                    PortSpec QuerySpec ScopeSpec
                    ServiceSpec SpecificationSpec
                    ValueObjectSpec ViewSpec WorkflowSpec]
    present = spec_names.select { |n| names.include?(n) }
    expect(present.size).to be >= 14
  end

  it "every spec generator aggregate has a description" do
    %w[AggregateSpec CommandSpec EventSpec
       PolicySpec WorkflowSpec].each do |n|
      agg = domain.aggregates.find { |a| a.name == n }
      expect(agg.description).not_to be_nil, "#{n} missing description"
    end
  end
end
