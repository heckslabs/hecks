# frozen_string_literal: true

require "spec_helper"
require_relative "support/pipeline_board_world"
require_relative "support/registry_store_spec_world"

# The records of a registry, kept for a few seconds so the readers of one refresh share a load.
RSpec.describe Hecks::Adapters::PipelineBoard::RegistryStore do
  include RegistryStoreSpecWorld

  let(:time) { [0.0] }
  let(:loads) { [] }

  it "loads an aggregate once for the readers of one refresh" do
    read_at(0.0, 1.0, 4.9)
    expect(loads.size).to eq(1)
  end

  it "loads it again after the cache window" do
    read_at(0.0, 6.0)
    expect(loads.size).to eq(2)
  end

  it "answers no events for a store that keeps no event log" do
    expect(described_class.new(registry: registry).events("Tickets", "Work")).to eq([])
  end

  it "answers the events of a store that keeps a log" do
    logged = registry
    logged.define_singleton_method(:repository) { |*| Struct.new(:events).new([:finished]) }
    expect(described_class.new(registry: logged).events("Tickets", "Work")).to eq([:finished])
  end

  it "says when the registry declares no such aggregate" do
    expect { described_class.new(registry: registry).records("Tickets", "Nope") }
      .to raise_error(Hecks::Adapters::PipelineBoard::Unavailable, /declares no Tickets.Nope/)
  end

  it "answers the events past a position, from the adapter's own lookup when it has one" do
    log = Struct.new(:events_past, :event_count).new([:new], 9)
    log.define_singleton_method(:events_past) { |position| position == 7 ? [:new] : [] }
    logged = registry.tap { |reg| reg.define_singleton_method(:repository) { |*| log } }
    store = described_class.new(registry: logged)
    expect([store.events_past("Tickets", "Work", 7), store.event_count("Tickets", "Work")]).to eq([[:new], 9])
  end

  it "cuts the events past a position from the whole log when the adapter has no lookup" do
    logged = registry
    logged.define_singleton_method(:repository) { |*| Struct.new(:events).new(%i[a b c]) }
    store = described_class.new(registry: logged)
    expect([store.events_past("Tickets", "Work", 1), store.event_count("Tickets", "Work")]).to eq([%i[b c], 3])
  end

  it "answers no events past a position for a store that keeps no event log" do
    store = described_class.new(registry: registry)
    expect([store.events_past("Tickets", "Work", 0), store.event_count("Tickets", "Work")]).to eq([[], 0])
  end
end
