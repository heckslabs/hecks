# CLI::CliTools paragraph spec
#
# Verifies CLI tool aggregates exist within the Cli domain.
#
require "spec_helper"
require "hecks/chapters/cli"

RSpec.describe Hecks::Chapters::Cli::CliTools do
  subject(:domain) { Hecks::Chapters::Cli.definition }

  it "includes SmokeTest with RunSmoke and CheckEvents commands" do
    agg = domain.aggregates.find { |a| a.name == "SmokeTest" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("RunSmoke", "CheckEvents")
  end

  it "includes DomainStats" do
    agg = domain.aggregates.find { |a| a.name == "DomainStats" }
    expect(agg).not_to be_nil
  end

  it "includes ImportPipeline with ParseModels and AssembleDomain" do
    agg = domain.aggregates.find { |a| a.name == "ImportPipeline" }
    expect(agg.commands.map(&:name)).to include("ParseModels", "AssembleDomain")
  end

  it "includes StubGenerator" do
    agg = domain.aggregates.find { |a| a.name == "StubGenerator" }
    expect(agg).not_to be_nil
  end

  it "includes DomainHelpers" do
    agg = domain.aggregates.find { |a| a.name == "DomainHelpers" }
    expect(agg).not_to be_nil
  end
end
