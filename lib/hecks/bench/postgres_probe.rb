module Hecks
  module Bench
    # Decides whether the Postgres targets can run at all.
    # A missing server or `pg` gem skips the target with a reason; settings come from libpq's env.
    module PostgresProbe
      module_function

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
