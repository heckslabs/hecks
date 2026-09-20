module Hecks
  module Adapters
    class Sqlite
      # The shared `events` table's own read/write — split out of the
      # `Sqlite` class body only to keep it under its line budget; every
      # method here stays public on `Sqlite` instances exactly as if it
      # were still defined there.
      module EventLog
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
end
