require "spec_helper"
require "hecks/chapters/bluebook"

RSpec.describe Hecks::Chapters::Bluebook::ValidationRulesParagraph do
  subject(:domain) { Hecks::Chapters::Bluebook.definition }

  let(:names) { domain.aggregates.map(&:name) }

  it "includes validation rule aggregates" do
    expect(names).to include("BaseRule", "ValidationMessage",
                             "CommandNaming", "AggregatesHaveCommands")
  end

  it "BaseRule has RunRule command" do
    agg = domain.aggregates.find { |a| a.name == "BaseRule" }
    expect(agg.commands.map(&:name)).to include("RunRule")
  end

  it "contributes at least 18 validation rule aggregates" do
    rule_names = %w[BaseRule ValidationMessage CommandNaming UniqueAggregateNames
                    SafeIdentifierNames ReservedNames NameCollisions
                    ComputedNameCollisions GlossaryTermViolations
                    AggregatesHaveCommands CommandsHaveAttributes
                    SingleAttributeAggregate TooManyCommands ValidPolicyEvents
                    ValidPolicyTriggers NoPiiInIdentity ValidReferences
                    NoSelfReferences NoBidirectionalReferences NoForeignKeyAttributes
                    Transparency Consent Privacy Security]
    present = rule_names.select { |n| names.include?(n) }
    expect(present.size).to be >= 18
  end

  it "every validation rule aggregate has a description" do
    %w[BaseRule CommandNaming AggregatesHaveCommands ValidReferences Transparency].each do |n|
      agg = domain.aggregates.find { |a| a.name == n }
      expect(agg.description).not_to be_nil, "#{n} missing description"
    end
  end
end
