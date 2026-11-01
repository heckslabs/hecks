require_relative "../../../ports/persistence/stored_name_guard"

module Hecks
  module Adapters
    class Postgres
      # Reads how many rows a table holds before any table is created, for the stored-name guard.
      module NameGuard
        private

        def refuse_orphaned_rows!
          Ports::Persistence::StoredNameGuard.check!(@aggregate, row_count: method(:rows_under))
        end

        def rows_under(name)
          [name, "#{name}_entries"].sum { |table| table_rows(table) }
        end

        def table_rows(table)
          exists = pg_exec_params("SELECT to_regclass($1) AS found", [quote_ident(table)])[0]["found"]
          exists ? pg_exec("SELECT COUNT(*) AS n FROM #{quote_ident(table)}")[0]["n"].to_i : 0
        end
      end
    end
  end
end
