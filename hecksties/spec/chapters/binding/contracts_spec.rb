require "spec_helper"
require "hecks/binding"

RSpec.describe Hecks::Binding::ContractsChapter do
  subject(:domain) { Hecks::Binding.definition }

  let(:names) { domain.aggregates.map(&:name) }

  it "includes contract aggregates" do
    expect(names).to include("Contracts", "TypeContract", "AggregateContract",
                             "CommandContract", "EventContract")
  end

  it "Contracts has Register and Lookup commands" do
    agg = domain.aggregates.find { |a| a.name == "Contracts" }
    cmds = agg.commands.map(&:name)
    expect(cmds).to include("Register", "Lookup")
  end

  it "RouteContract has Validate command" do
    agg = domain.aggregates.find { |a| a.name == "RouteContract" }
    expect(agg.commands.map(&:name)).to include("Validate")
  end

  it "contributes at least 12 contract aggregates" do
    contract_names = %w[Contracts TypeContract AggregateContract CommandContract
                        EventContract EventLogContract RouteContract DisplayContract
                        ViewContract FormParsingContract UILabelContract MigrationContract
                        DispatchContract ExtensionContract CsrfContract NamingContract]
    present = contract_names.select { |n| names.include?(n) }
    expect(present.size).to be >= 12
  end
end
