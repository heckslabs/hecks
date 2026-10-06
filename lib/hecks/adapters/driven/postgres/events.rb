module Hecks
  module Adapters
    class Postgres
      # Event log: every emitted event lands in the database's shared `events` table.
      module Events
        # Inserts an emitted event into the shared `events` table.
        #
        # @param event [Runtime::Event] the emitted event; `payload` is stored as JSON
        # @return [PG::Result] the insert's result; callers ignore it
        # @raise [PG::Error] if the insert fails
        def record_event(event)
          pg_exec_params(
            "INSERT INTO events (name, aggregate, aggregate_id, payload, occurred_at) VALUES ($1, $2, $3, $4, $5)",
            [event.name, event.aggregate, event.id.to_s, JSON.generate(event.payload), event.occurred_at]
          )
        end

        # Reads back every recorded event in insertion order — the whole `events` table, not
        # only this aggregate's rows.
        #
        # @return [Array<Runtime::Event>] the stored events, `payload` parsed with Symbol keys
        #   and `occurred_at` as the String Postgres returns; `[]` when none are recorded
        # @raise [PG::Error] if the statement fails
        def events
          pg_exec("SELECT * FROM events ORDER BY id").map { |row| event_from(row) }
        end

        # Reads back one record's recorded events, oldest first — pushed down as a `WHERE`
        # clause (`hecks_events_aggregate_id_idx`) instead of filtering `#events`'s whole-table
        # read, since a `corrects` command's history lookup only ever needs this one record.
        #
        # @param aggregate [String] the `"domain::AggregateName"` key events are stored under
        # @param id [String, Object] the record's identity, matched as `id.to_s`
        # @return [Array<Runtime::Event>] the record's stored events; `[]` when it has none
        # @raise [PG::Error] if the statement fails
        def events_for(aggregate:, id:)
          pg_exec_params(
            "SELECT * FROM events WHERE aggregate = $1 AND aggregate_id = $2 ORDER BY id",
            [aggregate, id.to_s]
          ).map { |row| event_from(row) }
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
