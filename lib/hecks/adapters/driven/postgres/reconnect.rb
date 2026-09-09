module Hecks
  module Adapters
    # SELF-HEALING CONNECTION — shared verbatim by `Postgres` and the era
    # plugin's `PostgresEra`, the same way `PostgresOutbox` (outbox.rb) is:
    # nothing here is lineage-specific, and `PostgresOutbox`'s own
    # `@db.exec*` calls route through this module's `pg_exec`/
    # `pg_exec_params` too, since both classes mix it in. Needs `@db` (a
    # `PG::Connection`), `@aggregate`, and `@settings` from the including
    # class — the same three `self.class.connect_for(@aggregate.name,
    # @settings)` already needs to build one in the first place.
    #
    # A backend killed out from under an adapter (a DBA's own
    # `pg_terminate_backend`, a load balancer's failover, a restart) —
    # chaos-tested against the plain `Postgres` adapter: `PG::ConnectionBad`
    # on the query that hit it, and PERMANENTLY on every query after,
    # since nothing ever replaced `@db` with a live connection.
    # `pg_exec`/`pg_exec_params` are the two primitives every other method
    # in either class funnels through — wrapping them here, once,
    # self-heals `@db` for the NEXT caller. THE CURRENT CALL STILL
    # RAISES — reconnecting cannot tell a caller whether ITS OWN write
    # reached the server before the connection died, so silently
    # retrying it here could silently double it; that ambiguity is
    # exactly why `Runtime::SagaInterpreter`'s own defect-retry exists
    # ONE LAYER UP, where a dispatch is retried as a whole (fresh
    # hydrate, fresh `given`s), not as a lone SQL statement.
    module PostgresReconnect
      def pg_exec(sql)
        @db.exec(sql)
      rescue PG::ConnectionBad
        reconnect!
        raise
      end

      def pg_exec_params(sql, binds)
        @db.exec_params(sql, binds)
      rescue PG::ConnectionBad
        reconnect!
        raise
      end

      private

      # BEST-EFFORT — a reconnect attempt that itself fails (the server
      # is actually down, not just this one backend) leaves `@db`
      # unchanged; the `PG::ConnectionBad` already being re-raised by
      # `pg_exec`/`pg_exec_params` above still reaches the caller either
      # way, so swallowing a failed RECONNECT attempt here loses no
      # information — it only avoids masking the original error with a
      # second one.
      def reconnect!
        @db = self.class.connect_for(@aggregate.name, @settings)
      rescue PG::Error
        nil
      end
    end
  end
end
