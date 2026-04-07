require "spec_helper"
require "hecks/chapters/binding"

RSpec.describe Hecks::Chapters::Binding do
  subject(:domain) { described_class.definition }

  it "returns a Domain named Binding" do
    expect(domain.name).to eq("Binding")
  end

  it "includes key aggregates" do
    names = domain.aggregates.map(&:name)
    expect(names).to include("NamingHelpers", "Utils", "Error", "ModuleDSL")
  end

  it "has commands on ModuleDSL" do
    agg = domain.aggregates.find { |a| a.name == "ModuleDSL" }
    expect(agg.commands.map(&:name)).to include("DefineRegistry")
  end

  it "has at least 20 aggregates (including sub-chapters)" do
    expect(domain.aggregates.size).to be >= 20
  end

  it "every aggregate has at least one command" do
    domain.aggregates.each do |agg|
      expect(agg.commands).not_to be_empty, "#{agg.name} has no commands"
    end
  end

  it "includes Registry and SetRegistry" do
    names = domain.aggregates.map(&:name)
    expect(names).to include("Registry", "SetRegistry")
  end

  it "includes Stats" do
    agg = domain.aggregates.find { |a| a.name == "Stats" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Compute")
  end

  it "includes HecksDeprecations" do
    agg = domain.aggregates.find { |a| a.name == "HecksDeprecations" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Register")
  end

  it "includes BindingSpine" do
    agg = domain.aggregates.find { |a| a.name == "BindingSpine" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Define")
  end
end
