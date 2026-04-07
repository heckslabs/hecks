# CLI::CliCommands paragraph spec
#
# Verifies CLI command aggregates exist within the Cli domain.
#
require "spec_helper"
require "hecks/chapters/cli"

RSpec.describe Hecks::Chapters::Cli::CliCommands do
  subject(:domain) { Hecks::Chapters::Cli.definition }

  it "includes InitCommand with Init command" do
    agg = domain.aggregates.find { |a| a.name == "InitCommand" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Init")
  end

  it "includes BuildCommand" do
    agg = domain.aggregates.find { |a| a.name == "BuildCommand" }
    expect(agg).not_to be_nil
  end

  it "includes ValidateCommand" do
    agg = domain.aggregates.find { |a| a.name == "ValidateCommand" }
    expect(agg).not_to be_nil
  end

  it "includes TreeCommand" do
    agg = domain.aggregates.find { |a| a.name == "TreeCommand" }
    expect(agg).not_to be_nil
  end

  it "includes at least 20 command aggregates" do
    cmd_aggs = domain.aggregates.select { |a| a.name.end_with?("Command") }
    expect(cmd_aggs.size).to be >= 20
  end
end
