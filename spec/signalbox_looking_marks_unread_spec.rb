# frozen_string_literal: true

require "spec_helper"
require "hecks/signalbox/adapters/looking"

# A world that declares a line the beat cannot read is reported, not replaced by starting values.
RSpec.describe Hecks::Adapters::Looking::Marks, "#initialize" do
  let(:broken) { Struct.new(:found) { def for_verb(_name) = raise("unreadable") }.new }
  let(:registry) { Struct.new(:found) { def world(_name) = found }.new(broken) }

  it "raises Unread naming the line" do
    expect { described_class.new(registry) }.to raise_error(described_class::Unread, /pressure line could not be read/)
  end

  it "keeps the starting values while no world is loaded" do
    expect(described_class.new(nil).facts).to include(stale_after: 120, load_short: 342)
  end

  it "refuses the look as unlooked" do
    look = Hecks::Adapters::Looking.new(registry: registry, settings: { machine: -> { { capacity_mb: 1 } } })
    expect { look.look(beat: "b") }.to raise_error(Hecks::Adapters::Looking::Unlooked, /could not be read/)
  end
end
