require "spec_helper"
require "hecks/chapters/bluebook"

RSpec.describe Hecks::Chapters::Bluebook::BehaviorParagraph do
  subject(:domain) { Hecks::Chapters::Bluebook.definition }

  let(:names) { domain.aggregates.map(&:name) }

  it "includes behavior IR aggregates" do
    expect(names).to include("Command", "DomainEvent", "Policy", "Saga")
  end

  it "CommandNode has DefineCommand" do
    agg = domain.aggregates.find { |a| a.name == "Command" }
    expect(agg.commands.map(&:name)).to include("DefineCommand")
  end

  it "DomainEvent has DefineEvent" do
    agg = domain.aggregates.find { |a| a.name == "DomainEvent" }
    expect(agg.commands.map(&:name)).to include("DefineEvent")
  end

  it "contributes at least 10 behavior aggregates" do
    behavior_names = %w[Command DomainEvent Query Policy Service
                        Condition EventSubscriber Specification Saga SagaStep
                        Workflow WorkflowStep]
    present = behavior_names.select { |n| names.include?(n) }
    expect(present.size).to be >= 10
  end

  it "every behavior aggregate has a description" do
    %w[Command DomainEvent Policy Saga].each do |n|
      agg = domain.aggregates.find { |a| a.name == n }
      expect(agg.description).not_to be_nil, "#{n} missing description"
    end
  end
end
