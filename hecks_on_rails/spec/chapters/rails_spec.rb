# Rails chapter self-description spec
#
# Verifies the Rails chapter defines a domain with ActiveModel
# compatibility, validation wiring, and generator aggregates.
#
require "spec_helper"
require "hecks/chapters/rails"

RSpec.describe Hecks::Chapters::Rails do
  subject(:domain) { described_class.definition }

  it "builds a domain named Rails" do
    expect(domain.name).to eq("Rails")
  end

  it "includes key aggregates" do
    names = domain.aggregates.map(&:name)
    expect(names).to include(
      "ActiveHecks", "DomainModelCompat", "AggregateCompat",
      "ValidationWiring", "Railtie"
    )
  end

  it "has at least 9 aggregates" do
    expect(domain.aggregates.size).to be >= 9
  end

  it "gives every aggregate at least one command" do
    domain.aggregates.each do |agg|
      expect(agg.commands).not_to be_empty, "#{agg.name} has no commands"
    end
  end

  it "every aggregate has a description" do
    domain.aggregates.each do |agg|
      expect(agg.description).not_to be_nil, "#{agg.name} has no description"
    end
  end

  it "defines Activate on ActiveHecks" do
    agg = domain.aggregates.find { |a| a.name == "ActiveHecks" }
    expect(agg.commands.map(&:name)).to include("Activate")
  end
end
