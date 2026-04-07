# CLI import paragraph spec
#
# Verifies the import pipeline paragraph defines aggregates for each
# import class with descriptions and commands.
#
require "spec_helper"
require "hecks/chapters/cli"

RSpec.describe Hecks::Chapters::Cli::CliImport do
  let(:domain) { Hecks::Chapters::Cli.definition }

  %w[
    DomainAssembler ModelParser ModelOnlyAssembler
    SchemaParser SchemaSandbox ColumnCollector PrismHelpers
  ].each do |name|
    it "defines #{name} aggregate with a description" do
      agg = domain.aggregates.find { |a| a.name == name }
      expect(agg).not_to be_nil, "Missing aggregate: #{name}"
      expect(agg.description).not_to be_empty
    end

    it "gives #{name} at least one command" do
      agg = domain.aggregates.find { |a| a.name == name }
      expect(agg.commands).not_to be_empty, "#{name} has no commands"
    end
  end
end
