module Hecks
  module Adapters
    class Sqlite
      # The outbox's public operations (see `Runtime::Outbox`) — split out
      # of the `Sqlite` class body only to keep it under its line budget;
      # every method here stays public/private on `Sqlite` instances
      # exactly as if it were still defined there. `outbox_claim` and
      # `outbox_settle` stay on the `Sqlite` class itself rather than
      # here — `.rubocop_todo.yml`'s own `Naming/PredicateMethod`
      # exclusion already names `sqlite.rb` for those two boolean-
      # returning methods, and this file isn't in that exclusion.
      module OutboxOperations
        # Inserts new outbox rows as pending, skipping any whose `delivery_id` already exists.
        #
        # The outbox — see `Runtime::Outbox`. Rows land in the same
        # database as this aggregate (the only way the enqueue shares the
        # save's transaction), keyed by the aggregate's storage name so an
        # adapter instance only ever reads back its own rows even when
        # several aggregates share one file. `INSERT OR IGNORE` on the
        # unique delivery_id makes a re-enqueue of the same (event,
        # consumer) a no-op; `outbox_claim`'s `WHERE status = 'pending'`
        # is the compare-and-set that lets exactly one relay win a row.
        #
        # @param rows [Array<Runtime::Outbox::Row>] rows to enqueue; each accepted row has its
        #   `id` and `status` assigned in place. `row.aggregate` is stored as given
        # @return [Array<Runtime::Outbox::Row>] the rows actually inserted, `[]` when every one
        #   was a duplicate
        # @raise [SQLite3::Exception] if an insert fails
        def outbox_enqueue(rows)
          rows.filter_map { |row| enqueue_row(row) }
        end

        # Lists the outbox rows whose `aggregate` column equals this adapter's `table`, in
        # enqueue order.
        #
        # @param status [String, Symbol, nil] only rows with this status; nil lists every row
        # @return [Array<Runtime::Outbox::Row>] the matching rows, `event` parsed with Symbol
        #   keys; `[]` when none match
        # @raise [SQLite3::Exception] if the statement fails
        def outbox_rows(status: nil)
          sql   = "SELECT * FROM hecks_outbox WHERE aggregate = ?"
          binds = [table]
          if status
            sql << " AND status = ?"
            binds << status.to_s
          end
          @db.execute("#{sql} ORDER BY id", binds).map { |row| outbox_row(row) }
        end

        private

        def enqueue_row(row)
          insert_outbox_row(row)
          return nil if @db.changes.zero?

          row.id = @db.last_insert_row_id
          row.status = "pending"
          row
        end

        def insert_outbox_row(row)
          @db.execute(
            "INSERT OR IGNORE INTO hecks_outbox (delivery_id, event_uid, aggregate, domain, kind, consumer, event, " \
            "status, attempts, enqueued_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?)",
            [row.delivery_id, row.event_uid, row.aggregate, row.domain, row.kind, row.consumer,
             JSON.generate(row.event), Time.now.utc.iso8601]
          )
        end

        def outbox_row(row)
          Runtime::Outbox::Row.new(
            id: row["id"], delivery_id: row["delivery_id"], event_uid: row["event_uid"], aggregate: row["aggregate"],
            domain: row["domain"], kind: row["kind"], consumer: row["consumer"],
            event: JSON.parse(row["event"], symbolize_names: true), status: row["status"],
            attempts: row["attempts"].to_i, error: row["error"]
          )
        end
      end
    end
  end
end
