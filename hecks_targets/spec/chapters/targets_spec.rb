# Targets chapter self-description spec
#
# Verifies the Targets chapter defines a domain with Go, Node, and
# Ruby paragraph aggregates plus the core Target aggregate.
#
require "spec_helper"
require "hecks/chapters/targets"

RSpec.describe Hecks::Chapters::Targets do
  subject(:domain) { described_class.definition }

  it "builds a domain named Targets" do
    expect(domain.name).to eq("Targets")
  end

  it "includes key aggregates" do
    names = domain.aggregates.map(&:name)
    expect(names).to include("Target", "GoCodeBuilder", "NodeUtils", "GemGenerator")
  end

  it "has at least 30 aggregates" do
    expect(domain.aggregates.size).to be >= 30
  end

  it "gives every aggregate at least one command" do
    domain.aggregates.each do |agg|
      expect(agg.commands).not_to be_empty, "#{agg.name} has no commands"
    end
  end

  it "defines RegisterTarget and Build on Target" do
    target = domain.aggregates.find { |a| a.name == "Target" }
    expect(target.commands.map(&:name)).to include("RegisterTarget", "Build")
  end
end
