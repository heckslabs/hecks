module Hecks
  module Adapters
    class Sqlite
      # Event log: every emitted event lands in the database's shared `events` table.
      module Events
        # Inserts an emitted event into the database's shared `events` table.
        #
        # @param event [Runtime::Event] the emitted event; `payload` is stored as JSON
        # @return [Array] the insert's empty result rows; callers ignore it
        # @raise [SQLite3::Exception] if the insert fails
        def record_event(event)
          @db.execute(
            "INSERT INTO events (name, aggregate, aggregate_id, payload, occurred_at) VALUES (?, ?, ?, ?, ?)",
            [event.name, event.aggregate, event.id.to_s, JSON.generate(event.payload), event.occurred_at]
          )
        end

        # Reads back every recorded event in insertion order — the database file's whole
        # `events` table, not only this aggregate's rows.
        #
        # @return [Array<Runtime::Event>] the stored events, `payload` parsed with Symbol keys
        #   and `occurred_at` as stored; `[]` when none are recorded
        # @raise [SQLite3::Exception] if the statement fails
        def events
          @db.execute("SELECT * FROM events ORDER BY id").map do |row|
            event_from(row)
          end
        end

        # Reads back one record's recorded events, oldest first — pushed down as a `WHERE`
        # clause (`hecks_events_aggregate_id_idx`) instead of filtering `#events`'s whole-table
        # read, since a `corrects` command's history lookup only ever needs this one record.
        #
        # @param aggregate [String] the `"domain::AggregateName"` key events are stored under
        # @param id [String, Object] the record's identity, matched as `id.to_s`
        # @return [Array<Runtime::Event>] the record's stored events; `[]` when it has none
        # @raise [SQLite3::Exception] if the statement fails
        def events_for(aggregate:, id:)
          @db.execute(
            "SELECT * FROM events WHERE aggregate = ? AND aggregate_id = ? ORDER BY id",
            [aggregate, id.to_s]
          ).map do |row|
            event_from(row)
          end
        end

        private

        def event_from(row)
          Runtime::Event.new(
            name:        row["name"],
            aggregate:   row["aggregate"],
            id:          row["aggregate_id"],
            payload:     JSON.parse(row["payload"], symbolize_names: true),
            occurred_at: row["occurred_at"]
          )
        end
      end
    end
  end
end
