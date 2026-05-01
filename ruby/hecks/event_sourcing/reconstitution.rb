# Hecks::EventSourcing::Reconstitution
#
# Reconstitutes aggregate state from an event stream, optionally starting
# from a snapshot. Applies each event through an `apply` hash that maps
# event types to state-transform procs. Supports auto-snapshotting at
# configurable intervals.
#
# == Usage
#
#   r = Reconstitution.new(event_store, snapshot_store: snap_store)
#   appliers = {
#     "CreatedPizza" => ->(state, data) { state.merge(name: data["name"]) },
#     "RenamedPizza" => ->(state, data) { state.merge(name: data["name"]) }
#   }
#   state = r.reconstitute("Pizza-1", appliers)
#   # => { name: "Margherita" }
#
class Hecks::EventSourcing::Reconstitution
  # @param event_store [Hecks::EventSourcing::EventStore]
  # @param snapshot_store [Hecks::EventSourcing::SnapshotStore, nil]
  # @param snapshot_interval [Integer, nil] auto-snapshot every N events
  def initialize(event_store, snapshot_store: nil, snapshot_interval: nil)
    @event_store = event_store
    @snapshot_store = snapshot_store
    @snapshot_interval = snapshot_interval
  end

  # Reconstitute aggregate state from snapshot + events.
  #
  # @param stream_id [String] the stream key
  # @param appliers [Hash{String => Proc}] event_type => state transform
  # @param initial_state [Hash] starting state if no snapshot (default {})
  # @return [Hash] the reconstituted state
  def reconstitute(stream_id, appliers, initial_state: {})
    state, from_version = load_snapshot(stream_id, initial_state)
    events = @event_store.read_stream(stream_id, from_version: from_version)

    events.each do |entry|
      applier = appliers[entry.event_type]
      state = applier.call(state, entry.data) if applier
    end

    maybe_snapshot(stream_id, state, events)
    state
  end

  private

  def load_snapshot(stream_id, initial_state)
    return [initial_state, 1] unless @snapshot_store

    snapshot = @snapshot_store.load(stream_id)
    if snapshot
      [snapshot.state.dup, snapshot.version + 1]
    else
      [initial_state, 1]
    end
  end

  def maybe_snapshot(stream_id, state, events)
    return unless @snapshot_store && @snapshot_interval && events.any?
    last_version = events.last.version
    return unless (last_version % @snapshot_interval).zero?
    @snapshot_store.save(stream_id, version: last_version, state: state.dup)
  end
end
