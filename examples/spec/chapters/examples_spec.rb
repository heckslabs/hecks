require "spec_helper"
require "hecks/chapters/examples"

RSpec.describe Hecks::Chapters::Examples do
  subject(:domain) { described_class.definition }

  it "returns a Domain named Examples" do
    expect(domain.name).to eq("Examples")
  end

  it "includes key example aggregates" do
    names = domain.aggregates.map(&:name)
    expect(names).to include("PizzasApp", "BankingApp", "MultiDomainApp",
                             "PizzasStaticRuby", "PizzasStaticGo")
  end

  it "every aggregate has at least one command" do
    domain.aggregates.each do |agg|
      expect(agg.commands).not_to be_empty, "#{agg.name} has no commands"
    end
  end

  it "every aggregate has a description" do
    domain.aggregates.each do |agg|
      expect(agg.description).not_to be_nil, "#{agg.name} has no description"
    end
  end
end
