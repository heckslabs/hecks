require "spec_helper"
require "hecks/chapters/bluebook"

RSpec.describe Hecks::Chapters::Bluebook::GeneratorsParagraph do
  subject(:domain) { Hecks::Chapters::Bluebook.definition }

  let(:names) { domain.aggregates.map(&:name) }

  it "includes code generator aggregates" do
    expect(names).to include("AggregateGenerator", "CommandGenerator",
                             "EventGenerator", "PolicyGenerator")
  end

  it "AggregateGenerator has GenerateAggregate command" do
    agg = domain.aggregates.find { |a| a.name == "AggregateGenerator" }
    expect(agg.commands.map(&:name)).to include("GenerateAggregate")
  end

  it "contributes at least 15 code generator aggregates" do
    gen_names = %w[AggregateGenerator CommandGenerator EntityGenerator EventGenerator
                   ValueObjectGenerator PolicyGenerator ServiceGenerator QueryGenerator
                   QueryObjectGenerator WorkflowGenerator LifecycleGenerator
                   SubscriberGenerator SpecificationGenerator ViewGenerator
                   DomainGemGenerator SpecGenerator PortGenerator
                   MemoryAdapterGenerator AutoloadGenerator SinatraGenerator
                   ConfigGenerator]
    present = gen_names.select { |n| names.include?(n) }
    expect(present.size).to be >= 15
  end

  it "every code generator aggregate has a description" do
    %w[AggregateGenerator CommandGenerator EventGenerator PolicyGenerator].each do |n|
      agg = domain.aggregates.find { |a| a.name == n }
      expect(agg.description).not_to be_nil, "#{n} missing description"
    end
  end
end
