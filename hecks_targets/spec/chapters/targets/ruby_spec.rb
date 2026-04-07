# Targets::Ruby paragraph spec
#
# Verifies Ruby paragraph aggregates exist within the Targets domain.
#
require "spec_helper"
require "hecks/chapters/targets"

RSpec.describe Hecks::Chapters::Targets::Ruby do
  subject(:domain) { Hecks::Chapters::Targets.definition }

  it "includes GemGenerator with Generate command" do
    agg = domain.aggregates.find { |a| a.name == "GemGenerator" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Generate")
  end

  it "includes EntryPointGenerator" do
    agg = domain.aggregates.find { |a| a.name == "EntryPointGenerator" }
    expect(agg).not_to be_nil
  end

  it "includes RuntimeWriter" do
    agg = domain.aggregates.find { |a| a.name == "RuntimeWriter" }
    expect(agg).not_to be_nil
  end

  it "includes RubyServerGenerator" do
    agg = domain.aggregates.find { |a| a.name == "RubyServerGenerator" }
    expect(agg).not_to be_nil
  end

  it "includes RubyUIGenerator" do
    agg = domain.aggregates.find { |a| a.name == "RubyUIGenerator" }
    expect(agg).not_to be_nil
  end
end
