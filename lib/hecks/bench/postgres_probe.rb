module Hecks
  module Bench
    # Decides whether the Postgres targets can run at all.
    #
    # Postgres is optional. A machine with no server, or without the `pg` gem, gets a
    # skipped target and a sentence saying why, never a stack trace. Connection
    # settings come from libpq's own environment (`PGHOST`, `PGPORT`, `PGUSER`,
    # `PGPASSWORD`), the same way the fuzzer's Postgres adapters read them.
    module PostgresProbe
      module_function

      # Tries to reach the server's maintenance database.
      #
      # @return [String, nil] nil when a server answered, otherwise one sentence saying why
      #   the Postgres targets cannot run
      def unavailable_reason
        require "pg"
        PG.connect(dbname: "postgres", connect_timeout: 2).close
        nil
      rescue LoadError
        "the `pg` gem is not installed"
      rescue PG::Error => e
        "no Postgres server is reachable (#{e.message.lines.first.to_s.strip}); start one, or point " \
        "PGHOST, PGPORT and PGUSER at one"
      end

      # Reads the server's version for the report's environment block.
      #
      # @return [String] the `server_version` setting, or `"unknown"` if it cannot be read
      def server_version
        require "pg"
        connection = PG.connect(dbname: "postgres", connect_timeout: 2)
        connection.exec("SHOW server_version").getvalue(0, 0)
      rescue LoadError, PG::Error
        "unknown"
      ensure
        connection&.close
      end
    end
  end
end
