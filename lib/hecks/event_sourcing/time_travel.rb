# Hecks::EventSourcing::TimeTravel
#
# Provides temporal queries against the event store: read aggregate state
# as of a specific timestamp or version. Combines EventStore stream reading
# with Reconstitution appliers to return historical state.
#
# == Usage
#
#   tt = TimeTravel.new(event_store)
#   appliers = { "CreatedPizza" => ->(s, d) { s.merge(name: d["name"]) } }
#
#   tt.as_of("Pizza-1", Time.now - 3600, appliers)
#   # => state as of one hour ago
#
#   tt.at_version("Pizza-1", 3, appliers)
#   # => state at version 3
#
class Hecks::EventSourcing::TimeTravel
  # @param event_store [Hecks::EventSourcing::EventStore]
  # @param snapshot_store [Hecks::EventSourcing::SnapshotStore, nil]
  def initialize(event_store, snapshot_store: nil)
    @event_store = event_store
    @snapshot_store = snapshot_store
  end

  # Reconstitute state as of a specific timestamp.
  #
  # @param stream_id [String] the stream key
  # @param timestamp [Time] the point in time
  # @param appliers [Hash{String => Proc}] event_type => state transform
  # @param initial_state [Hash] starting state (default {})
  # @return [Hash] the state at that point in time
  def as_of(stream_id, timestamp, appliers, initial_state: {})
    state = initial_state.dup
    events = @event_store.read_stream_until(stream_id, timestamp)
    events.each do |entry|
      applier = appliers[entry.event_type]
      state = applier.call(state, entry.data) if applier
    end
    state
  end

  # Reconstitute state at a specific version.
  #
  # @param stream_id [String] the stream key
  # @param version [Integer] the target version
  # @param appliers [Hash{String => Proc}] event_type => state transform
  # @param initial_state [Hash] starting state (default {})
  # @return [Hash] the state at that version
  def at_version(stream_id, version, appliers, initial_state: {})
    state = initial_state.dup
    events = @event_store.read_stream_to_version(stream_id, version)
    events.each do |entry|
      applier = appliers[entry.event_type]
      state = applier.call(state, entry.data) if applier
    end
    state
  end
end
