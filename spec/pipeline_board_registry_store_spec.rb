# frozen_string_literal: true

require "spec_helper"
require_relative "support/pipeline_board_world"

# The records of a registry, kept for a few seconds so the readers of one refresh share a load.
RSpec.describe Hecks::Adapters::PipelineBoard::RegistryStore do
  let(:time) { [0.0] }
  let(:loads) { [] }

  def book = Struct.new(:aggregates).new([Struct.new(:hecks_name).new("Work")])

  def registry
    book = self.book
    repository = Struct.new(:all).new([1])
    Class.new do
      define_method(:bluebook) { |_domain| book }
      define_method(:repository) { |*| repository }
    end.new
  end

  # A registry that counts each load of the aggregate.
  def counting
    counted = registry
    loads_seen = loads
    counted.define_singleton_method(:repository) { |*| Struct.new(:all).new(loads_seen.push(1) && [1]) }
    counted
  end

  def read_at(*seconds)
    store = described_class.new(registry: counting, clock: -> { time.first })
    seconds.each do |at|
      time[0] = at
      store.records("Tickets", "Work")
    end
  end

  it "loads an aggregate once for the readers of one refresh" do
    read_at(0.0, 1.0, 4.9)
    expect(loads.size).to eq(1)
  end

  it "loads it again after the cache window" do
    read_at(0.0, 6.0)
    expect(loads.size).to eq(2)
  end

  it "says when the registry declares no such aggregate" do
    expect { described_class.new(registry: registry).records("Tickets", "Nope") }
      .to raise_error(Hecks::Adapters::PipelineBoard::Unavailable, /declares no Tickets.Nope/)
  end
end
