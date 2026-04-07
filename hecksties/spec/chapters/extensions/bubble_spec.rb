# Extensions::BubbleChapter paragraph spec
#
# Verifies bubble anti-corruption layer aggregates exist within the Extensions domain.
#
require "spec_helper"
require "hecks/chapters/extensions"

RSpec.describe Hecks::Chapters::Extensions::BubbleChapter do
  subject(:domain) { Hecks::Chapters::Extensions.definition }

  it "includes AggregateMapper with TranslateLegacy command" do
    agg = domain.aggregates.find { |a| a.name == "AggregateMapper" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("TranslateLegacy", "ReverseTranslate")
  end

  it "includes Context with MapAggregate and Translate commands" do
    agg = domain.aggregates.find { |a| a.name == "Context" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("MapAggregate", "Translate")
  end
end
