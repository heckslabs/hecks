require "json"

module Hecks
  module Persistence
    # Hecks::Persistence::EventRecorder
    #
    # Records domain events to a SQL +domain_events+ table. Enabled via
    # +adapter :sql, event_sourced: true+ in +Hecks.configure+.
    # Provides aggregate history and full event stream queries.
    #
    # Events are stored in streams keyed by +"AggregateType-id"+ (e.g.,
    # +"Pizza-42"+) with monotonically increasing version numbers per stream.
    # Event data is serialized as JSON.
    #
    # The table is auto-created if it does not exist when the recorder is
    # instantiated (schema migration is handled internally).
    #
    # == Usage
    #
    #   recorder = EventRecorder.new(db)
    #   recorder.record("Pizza", pizza.id, created_event)
    #   recorder.history("Pizza", pizza.id)  # => [{ stream_id: "Pizza-1", ... }, ...]
    #   recorder.all_events                  # => all events across all streams
    #
    class EventRecorder
        # Creates a new EventRecorder backed by the given Sequel database connection.
        # Ensures the +domain_events+ table exists, creating it if necessary.
        #
        # @param db [Sequel::Database] the Sequel database connection to store events in
        def initialize(db)
          @db = db
          ensure_table
        end

        # Records a domain event to the event store.
        #
        # Constructs a stream ID from the aggregate type and ID, determines the
        # next version number for that stream, serializes the event data as JSON,
        # and inserts a row into the +domain_events+ table.
        #
        # @param aggregate_type [String] the aggregate type name (e.g., "Pizza")
        # @param aggregate_id [String, Integer] the ID of the aggregate instance
        # @param event [Object] the domain event object; must respond to +.class.name+
        #   and +.occurred_at+, plus accessor methods for its constructor parameters
        # @return [void]
        def record(aggregate_type, aggregate_id, event)
          stream_id = "#{aggregate_type}-#{aggregate_id}"
          version = next_version(stream_id)

          @db[:domain_events].insert(
            stream_id: stream_id,
            event_type: Hecks::Utils.const_short_name(event),
            data: serialize_event(event),
            occurred_at: event.occurred_at.iso8601,
            version: version
          )
        end

        # Retrieves the event history for a specific aggregate instance.
        #
        # Returns events ordered by version number (oldest first).
        #
        # @param aggregate_type [String] the aggregate type name (e.g., "Pizza")
        # @param aggregate_id [String, Integer] the ID of the aggregate instance
        # @return [Array<Hash>] array of event hashes, each containing:
        #   - +:stream_id+ [String] the event stream identifier
        #   - +:event_type+ [String] the short class name of the event
        #   - +:data+ [Hash] the deserialized event payload
        #   - +:occurred_at+ [String] ISO 8601 timestamp
        #   - +:version+ [Integer] the event's position in the stream
        def history(aggregate_type, aggregate_id)
          stream_id = "#{aggregate_type}-#{aggregate_id}"
          @db[:domain_events]
            .where(stream_id: stream_id)
            .order(:version)
            .all
            .map { |row| deserialize_row(row) }
        end

        # Retrieves all events across all streams, ordered by insertion order.
        #
        # @return [Array<Hash>] array of event hashes (same structure as +history+)
        def all_events
          @db[:domain_events].order(:id).all.map { |row| deserialize_row(row) }
        end

        private

        # Determines the next version number for the given stream.
        #
        # @param stream_id [String] the event stream identifier (e.g., "Pizza-42")
        # @return [Integer] the next version number (1-based)
        def next_version(stream_id)
          last = @db[:domain_events]
            .where(stream_id: stream_id)
            .max(:version)
          (last || 0) + 1
        end

        # Serializes a domain event's attributes to a JSON string.
        #
        # Introspects the event's constructor parameters (excluding +occurred_at+)
        # and reads each value via accessor methods.
        #
        # @param event [Object] the domain event to serialize
        # @return [String] JSON representation of the event's data attributes
        def serialize_event(event)
          attrs = {}
          event.class.instance_method(:initialize).parameters.each do |_, name|
            next unless name && name != :occurred_at
            attrs[name] = event.send(name) if event.respond_to?(name)
          end
          JSON.generate(attrs)
        end

        # Deserializes a database row into an event hash.
        #
        # @param row [Hash] a raw database row from the +domain_events+ table
        # @return [Hash] a normalized event hash with +:stream_id+, +:event_type+,
        #   +:data+ (parsed JSON), +:occurred_at+, and +:version+
        def deserialize_row(row)
          {
            stream_id: row[:stream_id],
            event_type: row[:event_type],
            data: JSON.parse(row[:data] || "{}"),
            occurred_at: row[:occurred_at],
            version: row[:version]
          }
        end

        # Creates the +domain_events+ table if it does not already exist.
        #
        # Schema:
        # - +id+ [Integer] auto-incrementing primary key
        # - +stream_id+ [String] the event stream identifier (indexed, not null)
        # - +event_type+ [String] the short class name of the event (not null)
        # - +data+ [Text] JSON-serialized event payload
        # - +occurred_at+ [String] ISO 8601 timestamp
        # - +version+ [Integer] the event's position within its stream
        #
        # @return [void]
        def ensure_table
          return if @db.table_exists?(:domain_events)

          @db.create_table(:domain_events) do
            primary_key :id
            String :stream_id, null: false
            String :event_type, null: false
            String :data, text: true
            String :occurred_at
            Integer :version
            index :stream_id
          end
        end
      end
  end
end
