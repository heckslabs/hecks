require "spec_helper"
require "hecks/chapters/bluebook"

RSpec.describe Hecks::Chapters::Bluebook::SerializersParagraph do
  subject(:domain) { Hecks::Chapters::Bluebook.definition }

  let(:names) { domain.aggregates.map(&:name) }

  it "includes serializer aggregates" do
    expect(names).to include("AggregateSerializer", "BehaviorSerializer",
                             "RuleSerializer", "TypeHelpers")
  end

  it "AggregateSerializer has SerializeAggregate command" do
    agg = domain.aggregates.find { |a| a.name == "AggregateSerializer" }
    expect(agg.commands.map(&:name)).to include("SerializeAggregate")
  end

  it "contributes at least 4 serializer aggregates" do
    ser_names = %w[AggregateSerializer BehaviorSerializer RuleSerializer TypeHelpers]
    present = ser_names.select { |n| names.include?(n) }
    expect(present.size).to be >= 4
  end

  it "every serializer aggregate has a description" do
    %w[AggregateSerializer BehaviorSerializer RuleSerializer TypeHelpers].each do |n|
      agg = domain.aggregates.find { |a| a.name == n }
      expect(agg.description).not_to be_nil, "#{n} missing description"
    end
  end
end
