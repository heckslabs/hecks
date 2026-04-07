require "spec_helper"
require "hecks/chapters/runtime"

RSpec.describe Hecks::Chapters::Runtime do
  subject(:domain) { described_class.definition }

  it "returns a Domain named Runtime" do
    expect(domain.name).to eq("Runtime")
  end

  it "includes key aggregates" do
    names = domain.aggregates.map(&:name)
    expect(names).to include("Runtime", "Configuration", "GateEnforcer",
                             "DryRunResult", "SagaRunner",
                             "Validations", "SmokeTest")
  end

  it "has commands on Runtime" do
    agg = domain.aggregates.find { |a| a.name == "Runtime" }
    cmds = agg.commands.map(&:name)
    expect(cmds).to include("Boot", "Load", "Configure")
  end

  it "has at least 70 aggregates (including sub-chapters)" do
    expect(domain.aggregates.size).to be >= 70
  end

  it "every aggregate has at least one command" do
    domain.aggregates.each do |agg|
      expect(agg.commands).not_to be_empty, "#{agg.name} has no commands"
    end
  end
end
