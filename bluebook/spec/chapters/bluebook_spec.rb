require "spec_helper"
require "hecks/chapters/bluebook"

RSpec.describe Hecks::Chapters::Bluebook do
  subject(:domain) { described_class.definition }

  it "returns a Domain named Bluebook" do
    expect(domain.name).to eq("Bluebook")
  end

  it "includes key aggregates" do
    names = domain.aggregates.map(&:name)
    expect(names).to include("Domain", "Aggregate", "Compiler", "Validator", "Grammar")
  end

  it "has commands on Domain" do
    agg = domain.aggregates.find { |a| a.name == "Domain" }
    cmds = agg.commands.map(&:name)
    expect(cmds).to include("DefineDomain", "ValidateDomain", "GenerateCode")
  end

  it "has commands on Aggregate" do
    agg = domain.aggregates.find { |a| a.name == "Aggregate" }
    cmds = agg.commands.map(&:name)
    expect(cmds).to include("AddAggregate", "AddAttribute", "AddCommand")
  end

  it "has at least 30 aggregates (including sub-chapters)" do
    expect(domain.aggregates.size).to be >= 30
  end

  it "every aggregate has at least one command" do
    domain.aggregates.each do |agg|
      expect(agg.commands).not_to be_empty, "#{agg.name} has no commands"
    end
  end
end
