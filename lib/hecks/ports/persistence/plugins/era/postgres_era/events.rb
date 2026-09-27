module Hecks
  module Adapters
    class PostgresEra
      # The shared `events` table: every domain's aggregates journal their emitted events
      # into it, keyed by `aggregate` ("domain::AggregateName") and `aggregate_id`.
      module Events
        # Stores one emitted event in the `events` table, shared by every aggregate on this
        # database and schema.
        #
        # @param event [Runtime::Event] the event to record; `correlation` is not stored
        # @return [PG::Result] the INSERT's result
        def record_event(event)
          @db.exec_params(
            "INSERT INTO events (name, aggregate, aggregate_id, payload, occurred_at) VALUES ($1, $2, $3, $4, $5)",
            [event.name, event.aggregate, event.id.to_s, JSON.generate(event.payload), event.occurred_at]
          )
        end

        # Reads every recorded event in the order recorded, across all aggregates.
        #
        # @return [Array<Runtime::Event>] events with symbol-keyed `payload` and `correlation` nil
        def events
          @db.exec("SELECT * FROM events ORDER BY id").map do |row|
            Runtime::Event.new(
              name:        row["name"],
              aggregate:   row["aggregate"],
              id:          row["aggregate_id"],
              payload:     JSON.parse(row["payload"], symbolize_names: true),
              occurred_at: row["occurred_at"]
            )
          end
        end

        # Reads back one record's recorded events, oldest first — pushed down as a `WHERE`
        # clause (`hecks_events_aggregate_id_idx`) instead of filtering `#events`'s whole-table
        # read, since a `corrects` command's history lookup only ever needs this one record.
        #
        # @param aggregate [String] the `"domain::AggregateName"` key events are stored under
        # @param id [String, Object] the record's identity, matched as `id.to_s`
        # @return [Array<Runtime::Event>] the record's stored events; `[]` when it has none
        def events_for(aggregate:, id:)
          @db.exec_params(
            "SELECT * FROM events WHERE aggregate = $1 AND aggregate_id = $2 ORDER BY id",
            [aggregate, id.to_s]
          ).map do |row|
            Runtime::Event.new(
              name:        row["name"],
              aggregate:   row["aggregate"],
              id:          row["aggregate_id"],
              payload:     JSON.parse(row["payload"], symbolize_names: true),
              occurred_at: row["occurred_at"]
            )
          end
        end

        private

        def create_event_table!
          @db.exec(<<~SQL)
            CREATE TABLE IF NOT EXISTS events (
              id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
              name         text NOT NULL,
              aggregate    text NOT NULL,
              aggregate_id text NOT NULL,
              payload      jsonb,
              occurred_at  text
            )
          SQL
          # Backs #events_for's per-record lookup (a `corrects` command's history read).
          @db.exec(
            "CREATE INDEX IF NOT EXISTS hecks_events_aggregate_id_idx ON events (aggregate, aggregate_id)"
          )
        end
      end
    end
  end
end
