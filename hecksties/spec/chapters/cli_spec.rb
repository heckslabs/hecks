# CLI chapter self-description spec
#
# Verifies the CLI chapter defines a domain with command and tool
# aggregates for the Thor-based CLI.
#
require "spec_helper"
require "hecks/chapters/cli"

RSpec.describe Hecks::Chapters::Cli do
  subject(:domain) { described_class.definition }

  it "builds a domain named Cli" do
    expect(domain.name).to eq("Cli")
  end

  it "includes key aggregates" do
    names = domain.aggregates.map(&:name)
    expect(names).to include("CLI", "Interviewer", "InitCommand")
  end

  it "has at least 27 aggregates" do
    expect(domain.aggregates.size).to be >= 27
  end

  it "gives every aggregate at least one command" do
    domain.aggregates.each do |agg|
      expect(agg.commands).not_to be_empty, "#{agg.name} has no commands"
    end
  end

  it "defines Start on CLI aggregate" do
    cli = domain.aggregates.find { |a| a.name == "CLI" }
    expect(cli.commands.map(&:name)).to include("Start")
  end
end
