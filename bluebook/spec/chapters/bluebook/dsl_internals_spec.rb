require "spec_helper"
require "hecks/chapters/bluebook"

RSpec.describe Hecks::Chapters::Bluebook::DslInternalsParagraph do
  subject(:domain) { Hecks::Chapters::Bluebook.definition }

  let(:names) { domain.aggregates.map(&:name) }

  it "includes DSL internal aggregates" do
    expect(names).to include("AggregateRebuilder", "AttributeCollector",
                             "BehaviorMethods", "ImplicitSyntax", "BluebookBuilder")
  end

  it "AttributeCollector has CollectAttribute command" do
    agg = domain.aggregates.find { |a| a.name == "AttributeCollector" }
    expect(agg.commands.map(&:name)).to include("CollectAttribute")
  end

  it "contributes at least 10 DSL internal aggregates" do
    dsl_names = %w[AggregateRebuilder AttributeCollector BehaviorMethods
                   ConstraintMethods ImplicitSyntax QueryMethods StepCollector
                   Describable BluebookBuilder DomainBuilderMethods]
    present = dsl_names.select { |n| names.include?(n) }
    expect(present.size).to be >= 10
  end

  it "every DSL internal aggregate has a description" do
    %w[AggregateRebuilder AttributeCollector BehaviorMethods BluebookBuilder].each do |n|
      agg = domain.aggregates.find { |a| a.name == n }
      expect(agg.description).not_to be_nil, "#{n} missing description"
    end
  end
end
