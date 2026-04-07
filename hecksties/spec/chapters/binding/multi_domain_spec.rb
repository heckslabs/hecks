require "spec_helper"
require "hecks/binding"

RSpec.describe Hecks::Binding::MultiDomainChapter do
  subject(:domain) { Hecks::Binding.definition }

  let(:names) { domain.aggregates.map(&:name) }

  it "includes multi-domain aggregates" do
    expect(names).to include("FilteredEventBus", "CrossDomainQuery", "Directionality")
  end

  it "FilteredEventBus has Subscribe and Publish commands" do
    agg = domain.aggregates.find { |a| a.name == "FilteredEventBus" }
    cmds = agg.commands.map(&:name)
    expect(cmds).to include("Subscribe", "Publish")
  end

  it "Directionality has Validate command" do
    agg = domain.aggregates.find { |a| a.name == "Directionality" }
    expect(agg.commands.map(&:name)).to include("Validate")
  end

  it "contributes at least 5 multi-domain aggregates" do
    multi_names = %w[FilteredEventBus CrossDomainQuery CrossDomainView
                     Directionality QueueWiring MultiDomainValidator]
    present = multi_names.select { |n| names.include?(n) }
    expect(present.size).to be >= 5
  end
end
