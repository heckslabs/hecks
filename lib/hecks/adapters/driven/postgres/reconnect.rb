module Hecks
  module Adapters
    # Replaces a dead `@db` after `PG::ConnectionBad`; shared by `Postgres` and `PostgresEra`.
    # Needs `@db`, `@aggregate` and `@settings`.
    module PostgresReconnect
      # Runs one parameterless statement, replacing a dead connection before re-raising.
      #
      # @param sql [String] the statement to run
      # @return [PG::Result] the statement's result
      # @raise [PG::ConnectionBad] if the connection died; `@db` is reconnected for the next
      #   caller, and this call is never retried
      # @raise [PG::Error] if the server rejects the statement
      def pg_exec(sql)
        @db.exec(sql)
      rescue PG::ConnectionBad
        reconnect!
        raise
      end

      # Runs one statement with bind parameters, replacing a dead connection before
      # re-raising.
      #
      # @param sql [String] the statement, with `$1`-style placeholders
      # @param binds [Array<Object>] one value per placeholder, in order; nil binds NULL
      # @return [PG::Result] the statement's result
      # @raise [PG::ConnectionBad] if the connection died; `@db` is reconnected for the next
      #   caller, and this call is never retried
      # @raise [PG::Error] if the server rejects the statement
      def pg_exec_params(sql, binds)
        @db.exec_params(sql, binds)
      rescue PG::ConnectionBad
        reconnect!
        raise
      end

      private

      # The failing call still raises and is never retried: it may have reached the server.
      # A failed reconnect is swallowed so it does not mask the original error.
      def reconnect!
        if @db.respond_to?(:reconnect!)
          @db.reconnect!
        else
          @db = self.class.connect_for(@aggregate.name, @settings)
        end
      rescue PG::Error, Runtime::WiringError
        nil
      end
    end
  end
end
