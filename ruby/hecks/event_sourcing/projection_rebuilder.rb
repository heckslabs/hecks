# Hecks::EventSourcing::ProjectionRebuilder
#
# Replays events from an EventStore through a set of projection procs
# to rebuild read model state from scratch. Used after deploying new
# projections or correcting projection bugs.
#
# == Usage
#
#   rebuilder = ProjectionRebuilder.new(event_store)
#   projections = { "CreatedPizza" => ->(e, state) { state.merge(count: (state[:count]||0)+1) } }
#   state = rebuilder.rebuild(projections)
#   # => { count: 3 }
#
#   # Rebuild from a specific stream:
#   state = rebuilder.rebuild_stream("Pizza-1", projections)
#
class Hecks::EventSourcing::ProjectionRebuilder
  # @param event_store [Hecks::EventSourcing::EventStore] the source of events
  # @param upcaster_engine [Hecks::EventSourcing::UpcasterEngine, nil] optional upcaster
  def initialize(event_store, upcaster_engine: nil)
    @event_store = event_store
    @upcaster_engine = upcaster_engine
  end

  # Replay all events through the given projections, building state from scratch.
  #
  # @param projections [Hash{String => Proc}] event_type => projection proc
  # @param initial_state [Hash] starting state (default empty hash)
  # @return [Hash] the rebuilt state
  def rebuild(projections, initial_state: {})
    state = initial_state.dup
    @event_store.all_events.each do |entry|
      state = apply_entry(entry, projections, state)
    end
    state
  end

  # Replay events from a single stream through projections.
  #
  # @param stream_id [String] the stream to replay
  # @param projections [Hash{String => Proc}] event_type => projection proc
  # @param initial_state [Hash] starting state (default empty hash)
  # @return [Hash] the rebuilt state
  def rebuild_stream(stream_id, projections, initial_state: {})
    state = initial_state.dup
    @event_store.read_stream(stream_id).each do |entry|
      state = apply_entry(entry, projections, state)
    end
    state
  end

  private

  def apply_entry(entry, projections, state)
    data = entry.data
    if @upcaster_engine
      data = @upcaster_engine.upcast(entry.event_type, data, from_version: entry.schema_version)
    end
    projection = projections[entry.event_type]
    projection ? projection.call(data, state) : state
  end
end
