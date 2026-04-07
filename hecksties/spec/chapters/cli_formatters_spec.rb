# CLI formatters paragraph spec
#
# Verifies the formatters paragraph defines aggregates for each
# domain inspector formatter with descriptions and commands.
#
require "spec_helper"
require "hecks/chapters/cli"

RSpec.describe Hecks::Chapters::Cli::CliFormatters do
  let(:domain) { Hecks::Chapters::Cli.definition }

  %w[
    AggregateFormatter BehaviorFormatters StructureFormatters
    LifecycleFormatter RuleFormatters SecondaryFormatters
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
