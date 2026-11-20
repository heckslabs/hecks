module Hecks
  module Adapters
    class D1
      # The one D1 batch for an atomic put that may take an ended occupant's id. Every statement
      # is gated in SQL, so the batch decides and writes with no read first: the status, the
      # occupant's archive under `<id>~<n>` (journal row, then head row), then the new record.
      # The archive id is the first free `<id>~<n>`, found by the same count `ReplaceWhen`
      # makes in Ruby.
      module ReplacingPut
        private

        # @return [Array<Array(String, Array)>] the batch's statements and their binds
        def replacing_statements(entry, insert_only, replace_when)
          [replacing_status_statement(entry, insert_only, replace_when),
           archive_entry_statement(entry, replace_when),
           archive_row_statement(entry, replace_when),
           *replacing_writes(entry, insert_only, replace_when)]
        end

        def replacing_status_statement(entry, insert_only, replace_when)
          live = insert_only ? "conflicted" : "replaced"
          ended_sql, ended_binds = ended_gate(entry, replace_when)
          ["SELECT CASE WHEN NOT EXISTS (SELECT 1 FROM #{quoted_table} WHERE id = ?) THEN 'inserted' " \
           "WHEN #{ended_sql} THEN 'replaced' ELSE '#{live}' END AS status", [entry.id.to_s] + ended_binds]
        end

        # The occupant's latest journal row, copied under the archive id.
        def archive_entry_statement(entry, replace_when)
          id_sql, id_binds = archive_id_sql(entry)
          ended_sql, ended_binds = ended_gate(entry, replace_when)
          ["INSERT INTO #{quoted_entry_table} (aggregate_id, operation, state, mirrors) " \
           "SELECT #{id_sql}, 'save', state, NULL FROM #{quoted_entry_table} " \
           "WHERE aggregate_id = ? AND #{ended_sql} ORDER BY sequence DESC LIMIT 1",
           id_binds + [entry.id.to_s] + ended_binds]
        end

        # The occupant's head row, copied under the archive id, its fields kept.
        def archive_row_statement(entry, replace_when)
          id_sql, id_binds = archive_id_sql(entry)
          ended_sql, ended_binds = ended_gate(entry, replace_when)
          columns = quoted_columns
          ["INSERT INTO #{quoted_table} (#{columns.join(", ")}) SELECT #{id_sql}, #{columns.drop(1).join(", ")} " \
           "FROM #{quoted_table} WHERE id = ? AND #{ended_sql}", id_binds + [entry.id.to_s] + ended_binds]
        end

        # The new record's journal row and head row, written unless a live occupant refuses them.
        def replacing_writes(entry, insert_only, replace_when)
          return [entry_statement(entry, false), aggregate_statement(entry, false)] unless insert_only

          gate = writable_gate(entry, replace_when)
          [gated_entry_statement(entry, gate), gated_row_statement(entry, gate)]
        end

        def gated_entry_statement(entry, (gate_sql, gate_binds))
          binds = [entry.id, entry.operation, state_json(entry.state), entry.mirrors && JSON.generate(entry.mirrors)]
          ["INSERT INTO #{quoted_entry_table} (aggregate_id, operation, state, mirrors) " \
           "SELECT ?, ?, ?, ? WHERE #{gate_sql}", binds + gate_binds]
        end

        def gated_row_statement(entry, (gate_sql, gate_binds))
          values = instance_values(Runtime::Instance.new(aggregate: @aggregate, id: entry.id, state: entry.state))
          ["INSERT OR REPLACE INTO #{quoted_table} (#{quoted_columns.join(", ")}) " \
           "SELECT #{slots(values)} WHERE #{gate_sql}", values + gate_binds]
        end

        def slots(values) = Array.new(values.size, "?").join(", ")

        def writable_gate(entry, replace_when)
          ended_sql, ended_binds = ended_gate(entry, replace_when)
          ["(NOT EXISTS (SELECT 1 FROM #{quoted_table} WHERE id = ?) OR #{ended_sql})", [entry.id.to_s] + ended_binds]
        end

        # Whether the occupant has ended: its status is marked reusable, or is no declared state.
        def ended_gate(entry, replace_when)
          field = quote_ident(replace_when.field.to_s)
          reusable = replace_when.reusable
          declared = replace_when.declared
          ["EXISTS (SELECT 1 FROM #{quoted_table} WHERE id = ? AND #{field} IS NOT NULL AND " \
           "(#{field} IN (#{slots(reusable)}) OR #{field} NOT IN (#{slots(declared)})))",
           [entry.id.to_s] + reusable + declared]
        end

        # The first `<id>~<n>` no head row holds, counted up from 1.
        def archive_id_sql(entry)
          ["(? || '~' || (WITH RECURSIVE n(k) AS (SELECT 1 UNION ALL SELECT k + 1 FROM n " \
           "WHERE EXISTS (SELECT 1 FROM #{quoted_table} WHERE id = ? || '~' || k)) SELECT MAX(k) FROM n))",
           [entry.id.to_s, entry.id.to_s]]
        end
      end
    end
  end
end
