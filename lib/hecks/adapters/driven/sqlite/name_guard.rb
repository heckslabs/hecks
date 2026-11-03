require_relative "../../../ports/persistence/stored_name_guard"

module Hecks
  module Adapters
    class Sqlite
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
          exists = @db.get_first_value("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [table])
          exists ? @db.get_first_value("SELECT COUNT(*) FROM #{quote_ident(table)}").to_i : 0
        end
      end
    end
  end
end
