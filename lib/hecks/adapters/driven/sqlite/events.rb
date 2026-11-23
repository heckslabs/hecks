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

        # Reads back the events past the first `position`, oldest first, so a follower that has
        # seen `position` entries reads only the new ones. The row id the position stands at is
        # remembered, so the next read from where this one ended is a single indexed lookup.
        #
        # @param position [Integer] how many events, from the oldest, the reader has already seen
        # @return [Array<Runtime::Event>] the events after those; `[]` when there are none
        # @raise [SQLite3::Exception] if a statement fails
        def events_past(position)
          position = [position - events_dropped, 0].max if position.positive?
          anchor = @event_anchor&.first == position ? @event_anchor.last : event_id_at(position)
          rows = @db.execute("SELECT * FROM events WHERE id > ? ORDER BY id", [anchor])
          @event_anchor = [position + rows.size, rows.empty? ? anchor : rows.last["id"]]
          rows.map { |row| event_from(row) }
        end

        # Counts the recorded events without reading them.
        #
        # @return [Integer] how many events the shared table holds
        # @raise [SQLite3::Exception] if the statement fails
        def event_count = @db.get_first_value("SELECT COUNT(*) FROM events").to_i + events_dropped

        # Counts the events recorded before `cutoff`, without dropping them.
        #
        # @param cutoff [String] an ISO 8601 UTC time; events with an earlier `occurred_at` count
        # @return [Integer] how many events a compaction at `cutoff` would drop
        # @raise [SQLite3::Exception] if the statement fails
        def events_before(cutoff)
          @db.get_first_value("SELECT COUNT(*) FROM events WHERE occurred_at < ?", [cutoff]).to_i
        end

        # Drops the events recorded before `cutoff`, and counts them as dropped so `event_count`
        # and the positions `events_past` takes keep meaning what they meant. The delete and the
        # count move together or not at all. Positions shift by the dropped count, so the remembered
        # anchor is forgotten; the row ids themselves never move.
        #
        # @param cutoff [String] an ISO 8601 UTC time; events with an earlier `occurred_at` go
        # @return [Integer] how many events were dropped
        # @raise [SQLite3::Exception] if a statement fails; nothing is then dropped
        def compact_events!(before:)
          @db.transaction do
            @db.execute("DELETE FROM events WHERE occurred_at < ?", [before])
            removed = @db.changes
            record_events_dropped!(removed)
            @event_anchor = nil
            removed
          end
        end

        # How many events compaction has dropped from the oldest end of the log.
        #
        # @return [Integer] `0` when nothing was ever dropped
        # @raise [SQLite3::Exception] if the statement fails
        def events_dropped
          @db.get_first_value("SELECT dropped FROM hecks_event_compaction").to_i
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

        def record_events_dropped!(removed)
          @db.execute("INSERT INTO hecks_event_compaction (id, dropped) VALUES (1, ?) " \
                      "ON CONFLICT (id) DO UPDATE SET dropped = dropped + excluded.dropped", [removed])
        end

        # The id of the event at `position`, counted from one: 0 before the first event, and the
        # newest id when the table holds fewer events than that.
        def event_id_at(position)
          return 0 unless position.positive?

          at = @db.get_first_value("SELECT id FROM events ORDER BY id LIMIT 1 OFFSET ?", [position - 1])
          (at || @db.get_first_value("SELECT MAX(id) FROM events")).to_i
        end

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
