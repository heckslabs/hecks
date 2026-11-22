# frozen_string_literal: true

# A Work aggregate's event log that answers only what is past a position, and counts what it reads.
class RegistryStoreEventLog
  attr_reader :read_whole, :read_past

  def initialize(*events)
    @events = events
    @read_whole = 0
    @read_past = []
  end

  def append(*more) = @events.concat(more)

  def replace(*events) = @events = events

  def events
    @read_whole += 1
    @events.dup
  end

  def events_past(position)
    @read_past << position
    @events.drop(position)
  end

  def event_count = @events.size
end

# The registries the cursor spec reads a log through.
module RegistryStoreEventLogWorld
  def registry_of(log)
    book = Struct.new(:aggregates).new([Struct.new(:hecks_name).new("Work")])
    Class.new do
      define_method(:bluebook) { |_domain| book }
      define_method(:repository) { |*| log }
    end.new
  end

  def store_over(log, registry: registry_of(log))
    described_class.new(registry: registry, clock: -> { time[0] })
  end

  def refresh(store, at)
    time[0] = at
    store.events("Tickets", "Work")
  end
end
