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
end
