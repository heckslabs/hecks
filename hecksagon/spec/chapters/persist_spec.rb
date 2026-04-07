require "spec_helper"
require "hecks/chapters/persist"

RSpec.describe Hecks::Chapters::Persist do
  subject(:domain) { described_class.definition }

  it "returns a Domain named Persist" do
    expect(domain.name).to eq("Persist")
  end

  it "includes all persistence aggregates" do
    names = domain.aggregates.map(&:name)
    expect(names).to include("DatabaseConnection", "SqlAdapterGenerator",
                             "SqlBuilder", "SqlMigrationGenerator",
                             "SqlStrategy", "SqlHelpers",
                             "SqlBoot", "SqlSetup")
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
