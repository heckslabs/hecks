require "spec_helper"
require "hecks/chapters/bluebook"

RSpec.describe Hecks::Chapters::Bluebook::BuildersParagraph do
  subject(:domain) { Hecks::Chapters::Bluebook.definition }

  let(:names) { domain.aggregates.map(&:name) }

  it "includes builder aggregates" do
    expect(names).to include("DomainBuilder", "AggregateBuilder",
                             "CommandBuilder", "PolicyBuilder")
  end

  it "DomainBuilder has BuildDomain command" do
    agg = domain.aggregates.find { |a| a.name == "DomainBuilder" }
    expect(agg.commands.map(&:name)).to include("BuildDomain")
  end

  it "contributes at least 15 builder aggregates" do
    builder_names = %w[DomainBuilder AggregateBuilder CommandBuilder EntityBuilder
                       EventBuilder ValueObjectBuilder PolicyBuilder ServiceBuilder
                       WorkflowBuilder LifecycleBuilder ReadModelBuilder SagaBuilder
                       SagaStepBuilder GlossaryBuilder ModuleBuilder AclBuilder
                       BranchBuilder ScheduledStepBuilder]
    present = builder_names.select { |n| names.include?(n) }
    expect(present.size).to be >= 15
  end

  it "every builder aggregate has a description" do
    %w[DomainBuilder AggregateBuilder CommandBuilder PolicyBuilder].each do |n|
      agg = domain.aggregates.find { |a| a.name == n }
      expect(agg.description).not_to be_nil, "#{n} missing description"
    end
  end
end
