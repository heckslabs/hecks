module Hecks
  module Adapters
    class Sqlite
      # The transactional outbox rows, keyed by this aggregate's storage name.
      module Outbox
        # Inserts new outbox rows as pending, skipping any whose `delivery_id` already exists.
        #
        # Rows share this aggregate's database so the enqueue joins the save's transaction, and
        # are keyed by storage name so aggregates sharing a file read back only their own.
        #
        # @param rows [Array<Runtime::Outbox::Row>] rows to enqueue; each accepted row has its
        #   `id` and `status` assigned in place. `row.aggregate` is stored as given
        # @return [Array<Runtime::Outbox::Row>] the rows actually inserted, `[]` when every one
        #   was a duplicate
        # @raise [SQLite3::Exception] if an insert fails
        def outbox_enqueue(rows)
          rows.filter_map do |row|
            insert_outbox_row(row)
            next nil if @db.changes.zero?

            row.id = @db.last_insert_row_id
            row.status = "pending"
            row
          end
        end

        # Claims a pending outbox row with a compare-and-set update, counting the attempt.
        #
        # @param id [Integer] the row id `outbox_enqueue` assigned
        # @return [Boolean] true when the row was pending and is now claimed; false when it is
        #   unknown or another claimer got there first
        # @raise [SQLite3::Exception] if the update fails
        def outbox_claim(id) # rubocop:disable Naming/PredicateMethod -- the outbox port's verb
          @db.execute(
            "UPDATE hecks_outbox SET status = 'claimed', attempts = attempts + 1, claimed_at = ? " \
            "WHERE id = ? AND status = 'pending'",
            [Time.now.utc.iso8601, id]
          )
          @db.changes == 1
        end

        # Records a delivery outcome and its settle time on an outbox row, whatever status it
        # held.
        #
        # @param id [Integer] the row id `outbox_enqueue` assigned
        # @param status [String, Symbol] the new status, one of `Runtime::Outbox::STATUSES`;
        #   not validated here
        # @param error [String, nil] the failure description, or nil to store NULL
        # @return [Boolean] true when exactly one row was updated; false when no row has `id`
        # @raise [SQLite3::Exception] if the update fails
        def outbox_settle(id, status:, error: nil) # rubocop:disable Naming/PredicateMethod -- the outbox port's verb
          @db.execute(
            "UPDATE hecks_outbox SET status = ?, error = ?, settled_at = ? WHERE id = ?",
            [status.to_s, error, Time.now.utc.iso8601, id]
          )
          @db.changes == 1
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
