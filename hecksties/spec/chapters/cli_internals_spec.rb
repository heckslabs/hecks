# CLI internals paragraph spec
#
# Verifies the internals paragraph defines aggregates for version log
# formatting, tour steps, and Sinatra generation.
#
require "spec_helper"
require "hecks/chapters/cli"

RSpec.describe Hecks::Chapters::Cli::CliInternals do
  let(:domain) { Hecks::Chapters::Cli.definition }

  %w[VersionLogFormatter Steps SinatraAppGenerator].each do |name|
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
