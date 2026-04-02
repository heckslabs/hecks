# Hecks::EventSourcing::EventStore
#
# In-memory event store for event sourcing. Stores events in append-only
# streams keyed by stream_id (e.g. "Pizza-42"). Each event has a version,
# schema_version, and timestamp. Used as the source of truth for projection
# rebuilds, time travel, and aggregate reconstitution.
#
# == Usage
#
#   store = EventStore.new
#   store.append("Pizza-1", { type: "CreatedPizza", data: {...} })
#   store.read_stream("Pizza-1")  # => [entry, ...]
#   store.all_events               # => [entry, ...]
#
class Hecks::EventSourcing::EventStore
  Entry = Struct.new(:stream_id, :event_type, :data, :version, :schema_version,
                     :occurred_at, :global_position, keyword_init: true)

  # @return [Array<Entry>] all events in global order
  attr_reader :events

  def initialize
    @streams = Hash.new { |h, k| h[k] = [] }
    @events = []
    @mutex = Mutex.new
    @global_position = 0
  end

  # Append an event to a stream. Auto-assigns version and global position.
  #
  # @param stream_id [String] the stream key (e.g. "Pizza-42")
  # @param event_type [String] the event class name
  # @param data [Hash] the event payload
  # @param schema_version [Integer] event schema version (default 1)
  # @param occurred_at [Time] when the event occurred
  # @param expected_version [Integer, nil] optimistic lock check
  # @return [Entry] the appended event entry
  # @raise [Hecks::ConcurrencyError] if expected_version mismatches
  def append(stream_id, event_type:, data:, schema_version: 1,
             occurred_at: Time.now, expected_version: nil)
    @mutex.synchronize do
      stream = @streams[stream_id]
      current = stream.last&.version || 0

      if expected_version && expected_version != current
        raise Hecks::ConcurrencyError,
          "Expected version #{expected_version} but stream has #{current}"
      end

      @global_position += 1
      entry = Entry.new(
        stream_id: stream_id,
        event_type: event_type.to_s,
        data: data,
        version: current + 1,
        schema_version: schema_version,
        occurred_at: occurred_at,
        global_position: @global_position
      )
      stream << entry
      @events << entry
      entry
    end
  end

  # Read all events from a stream, optionally starting from a version.
  #
  # @param stream_id [String] the stream key
  # @param from_version [Integer] start reading from this version (default 1)
  # @return [Array<Entry>] events in version order
  def read_stream(stream_id, from_version: 1)
    @mutex.synchronize do
      @streams[stream_id].select { |e| e.version >= from_version }
    end
  end

  # Read events up to a specific version.
  #
  # @param stream_id [String] the stream key
  # @param to_version [Integer] read up to and including this version
  # @return [Array<Entry>] events up to the target version
  def read_stream_to_version(stream_id, to_version)
    @mutex.synchronize do
      @streams[stream_id].select { |e| e.version <= to_version }
    end
  end

  # Read events up to a specific timestamp.
  #
  # @param stream_id [String] the stream key
  # @param timestamp [Time] read events up to this time
  # @return [Array<Entry>] events before or at the timestamp
  def read_stream_until(stream_id, timestamp)
    @mutex.synchronize do
      @streams[stream_id].select { |e| e.occurred_at <= timestamp }
    end
  end

  # Return all events across all streams in global order.
  #
  # @return [Array<Entry>] all events
  def all_events
    @mutex.synchronize { @events.dup }
  end

  # Return the current version for a stream.
  #
  # @param stream_id [String] the stream key
  # @return [Integer] the latest version (0 if empty)
  def stream_version(stream_id)
    @mutex.synchronize { @streams[stream_id].last&.version || 0 }
  end

  # Remove all events. For testing only.
  #
  # @return [void]
  def clear
    @mutex.synchronize do
      @streams.clear
      @events.clear
      @global_position = 0
    end
  end
end
