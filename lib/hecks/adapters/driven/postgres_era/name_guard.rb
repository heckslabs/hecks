require_relative "../../../ports/persistence/stored_name_guard"

module Hecks
  module Adapters
    class PostgresEra
      # Counts the journal rows each stored name holds, for the stored-name guard. PostgresEra keeps
      # no table per aggregate: its rows are journal rows keyed by storage name, in every era.
      module NameGuard
        private

        def refuse_orphaned_rows!
          Ports::Persistence::StoredNameGuard.check!(@aggregate, row_count: method(:journal_rows))
        end

        def journal_rows(name)
          @db.exec_params(
            "SELECT count(*) FROM #{@lineage.quoted_journal} WHERE aggregate = $1", [name]
          )[0]["count"].to_i
        end
      end
    end
  end
end
