require "json"
require_relative "../../../runtime/outbox"

module Hecks
  module Adapters
    # THE OUTBOX, POSTGRES-SHAPED — shared verbatim by `Postgres` and the
    # era plugin's `PostgresEra`, the same way their `events` and
    # `hecks_saga_instances` DDL is copied between them: nothing here is
    # lineage-specific. Needs `@db` (a `PG::Connection`) and `table`
    # (the aggregate's storage name) from the including class. See
    # `Runtime::Outbox` for what the four verbs mean, and Sqlite's copy
    # for the SQL idioms (`ON CONFLICT DO NOTHING` = idempotent enqueue,
    # `WHERE status = 'pending'` = the compare-and-set claim).
    module PostgresOutbox
      # RE-ENTRANT — `Interpreting#run_dispatch_order` opens one
      # transaction around save+emit+outbox and the adapter's own
      # `append`/`atomic_put`/`delete` each open theirs; PG refuses
      # BEGIN inside BEGIN, so an inner call joins the open one.
      def transaction(&)
        return yield unless @db.transaction_status == PG::PQTRANS_IDLE

        @db.transaction(&)
      end

      def outbox_enqueue(rows)
        rows.filter_map do |row|
          result = @db.exec_params(
            "INSERT INTO hecks_outbox (delivery_id, event_uid, aggregate, domain, kind, consumer, event, status, attempts) " \
            "VALUES ($1, $2, $3, $4, $5, $6, $7, 'pending', 0) ON CONFLICT (delivery_id) DO NOTHING RETURNING id",
            [row.delivery_id, row.event_uid, row.aggregate, row.domain, row.kind, row.consumer, JSON.generate(row.event)]
          )
          next nil if result.ntuples.zero?

          row.id = result[0]["id"].to_i
          row.status = "pending"
          row
        end
      end

      def outbox_claim(id) # rubocop:disable Naming/PredicateMethod
        @db.exec_params(
          "UPDATE hecks_outbox SET status = 'claimed', attempts = attempts + 1, claimed_at = now() " \
          "WHERE id = $1 AND status = 'pending'",
          [id]
        ).cmd_tuples == 1
      end

      def outbox_settle(id, status:, error: nil) # rubocop:disable Naming/PredicateMethod
        @db.exec_params(
          "UPDATE hecks_outbox SET status = $2, error = $3, settled_at = now() WHERE id = $1",
          [id, status.to_s, error]
        ).cmd_tuples == 1
      end

      def outbox_rows(status: nil)
        sql   = "SELECT * FROM hecks_outbox WHERE aggregate = $1"
        binds = [table]
        if status
          sql << " AND status = $2"
          binds << status.to_s
        end
        @db.exec_params("#{sql} ORDER BY id", binds).map do |row|
          Runtime::Outbox::Row.new(
            id: row["id"].to_i, delivery_id: row["delivery_id"], event_uid: row["event_uid"], aggregate: row["aggregate"],
            domain: row["domain"], kind: row["kind"], consumer: row["consumer"],
            event: JSON.parse(row["event"], symbolize_names: true), status: row["status"],
            attempts: row["attempts"].to_i, error: row["error"]
          )
        end
      end

      private

      def create_outbox_table!
        @db.exec(<<~SQL)
          CREATE TABLE IF NOT EXISTS hecks_outbox (
            id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            delivery_id  text NOT NULL UNIQUE,
            event_uid    text NOT NULL,
            aggregate    text NOT NULL,
            domain       text NOT NULL,
            kind         text NOT NULL,
            consumer     text NOT NULL,
            event        jsonb NOT NULL,
            status       text NOT NULL DEFAULT 'pending',
            attempts     integer NOT NULL DEFAULT 0,
            error        text,
            enqueued_at  timestamptz NOT NULL DEFAULT now(),
            claimed_at   timestamptz,
            settled_at   timestamptz
          )
        SQL
        @db.exec("CREATE INDEX IF NOT EXISTS idx_hecks_outbox_status ON hecks_outbox(aggregate, status)")
      end
    end
  end
end
