# Hecks::EventSourcing::SnapshotStore
#
# In-memory snapshot store for event-sourced aggregates. Stores a
# serialized aggregate state at a specific version, so reconstitution
# can skip replaying events from the beginning.
#
# == Usage
#
#   store = SnapshotStore.new
#   store.save("Pizza-1", version: 10, state: { name: "Margherita" })
#   store.load("Pizza-1")  # => { version: 10, state: { name: "Margherita" } }
#
class Hecks::EventSourcing::SnapshotStore
  # Hecks::EventSourcing::SnapshotStore::Snapshot
  #
  # Immutable record storing a serialized aggregate state at a specific version for fast reconstitution.
  #
  Snapshot = Struct.new(:stream_id, :version, :state, :taken_at, keyword_init: true)

  def initialize
    @snapshots = {}
    @mutex = Mutex.new
  end

  # Save a snapshot for a stream.
  #
  # @param stream_id [String] the stream key (e.g. "Pizza-42")
  # @param version [Integer] the event version this snapshot is at
  # @param state [Hash] the serialized aggregate state
  # @return [Snapshot]
  def save(stream_id, version:, state:)
    @mutex.synchronize do
      snapshot = Snapshot.new(
        stream_id: stream_id, version: version,
        state: state, taken_at: Time.now
      )
      @snapshots[stream_id] = snapshot
      snapshot
    end
  end

  # Load the latest snapshot for a stream.
  #
  # @param stream_id [String] the stream key
  # @return [Snapshot, nil] the snapshot or nil if none exists
  def load(stream_id)
    @mutex.synchronize { @snapshots[stream_id] }
  end

  # Remove a snapshot for a stream.
  #
  # @param stream_id [String] the stream key
  # @return [void]
  def delete(stream_id)
    @mutex.synchronize { @snapshots.delete(stream_id) }
  end

  # Remove all snapshots. For testing only.
  #
  # @return [void]
  def clear
    @mutex.synchronize { @snapshots.clear }
  end
end
