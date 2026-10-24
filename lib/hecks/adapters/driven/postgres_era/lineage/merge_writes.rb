module Hecks
  module Adapters
    class PostgresEra
      class Lineage
        # The row-level steps of a tail merge: finding the ids both worlds touched, capturing the
        # new world's head states, rebuilding the heads, and writing each winner back.
        module MergeWrites
          # The ids written by both worlds since the cut.
          CONFLICT_SQL = <<~SQL.freeze
            SELECT aggregate_id FROM %<journal>s
            WHERE era < %<era>s AND aggregate IN (%<olds>s) AND ordinal > %<cut>s
            INTERSECT
            SELECT aggregate_id FROM %<journal>s
            WHERE era = %<era>s AND aggregate = %<current>s
          SQL

          # Ids written by both worlds since the cut, as `[storage_name, aggregate_id]` pairs.
          #
          # Compares raw ids: a rekeyed record's pre- and post-rekey rows never intersect and
          # survive as two separate heads (a duplicate, not corruption); resolve by hand.
          def conflict_ids(aggregate, edges, era, cut)
            names = names_by_era(aggregate, edges)
            rows = @db.exec(conflict_sql(names, era, cut))
            rows.map { |row| [aggregate.storage_name, row["aggregate_id"]] }
          end

          private

          def conflict_sql(names, era, cut)
            olds = (1...era).map { |ancestor| text_literal(names[:storage][ancestor - 1]) }.join(", ")
            format(CONFLICT_SQL, journal: quoted_journal, era: era.to_i, olds: olds, cut: cut.to_i,
                                 current: text_literal(names[:storage][era - 1]))
          end

          # The new world's pre-merge head states, captured before the
          # rebuild lets the tail interleave.
          def pre_merge_states(merge)
            new_ids = merge.winners.select { |_, side| side == "new" }.keys
            merge.aggregates.each_with_object({}) do |aggregate, states|
              new_ids.each do |id|
                state = head_state(aggregate, id)
                states[id] = [aggregate.storage_name, state] if state
              end
            end
          end

          # The record's state in the aggregate's current head, or nil when it is not there.
          def head_state(aggregate, id)
            row = @db.exec_params("SELECT state FROM #{quote(head_view(aggregate.storage_name))} WHERE id = $1", [id])
            row[0]["state"] if row.ntuples.positive?
          end

          def recompile_heads!(merge)
            @db.exec_params("UPDATE hecks_eras SET watermark = $2 WHERE domain = $1 AND ordinal > 1", [@domain, merge.tip])
            merge.aggregates.each do |aggregate|
              drop_head!(aggregate, merge)
              # full: the watermarks just moved — every ancestor matview's
              # cut is stale, so there is nothing safe to layer on.
              compile_head!(aggregate, merge.era, merge.label, merge.edges, full: true)
            end
          end

          def drop_head!(aggregate, merge)
            @db.exec("DROP VIEW IF EXISTS #{quote(head_view(aggregate.storage_name))}")
            @db.exec("DROP MATERIALIZED VIEW IF EXISTS #{quote(matview(aggregate.storage_name, merge.era, merge.label))}")
          end

          def reinsert_winners!(merge, new_states)
            merge.winners.each do |id, side|
              merge.aggregates.each do |aggregate|
                state = winner_state(merge, aggregate, id, side, new_states)
                write_winner!(merge, aggregate, id, state) if state
              end
            end
          end

          # The winning state of one record: the old world's from the rebuilt matview, the new
          # world's from the states captured before the rebuild; nil when this aggregate has none.
          def winner_state(merge, aggregate, id, side, new_states)
            return new_winner_state(aggregate, id, new_states) unless side == "old"

            row = @db.exec_params(
              "SELECT state FROM #{quote(matview(aggregate.storage_name, merge.era, merge.label))} " \
              "WHERE aggregate_id = $1 AND operation = 'save' ORDER BY ordinal DESC LIMIT 1",
              [id]
            )
            row.ntuples.positive? ? row[0]["state"] : nil
          end

          def new_winner_state(aggregate, id, new_states)
            new_states[id]&.first == aggregate.storage_name ? new_states[id][1] : nil
          end

          # Journal first, snapshot second, as a live write does: this INSERT bypasses
          # PostgresEra#append, and head_view reads live rows from the snapshot table.
          def write_winner!(merge, aggregate, id, state)
            ordinal = @db.exec_params(
              "INSERT INTO #{quoted_journal} (era, aggregate, aggregate_id, operation, state) " \
              "VALUES ($1, $2, $3, 'save', $4) RETURNING ordinal",
              [merge.era, aggregate.storage_name, id, state]
            )[0]["ordinal"]
            upsert_winner_snapshot!(snapshot: quote(head_snapshot(aggregate.storage_name, merge.era)),
                                    id: id, ordinal: ordinal, state: state)
          end

          # Always 'save': winners come from save-only sources, never a delete.
          def upsert_winner_snapshot!(snapshot:, id:, ordinal:, state:)
            @db.exec_params(
              "INSERT INTO #{snapshot} (id, ordinal, operation, state) " \
              "VALUES ($1, $2, 'save', $3) " \
              "ON CONFLICT (id) DO UPDATE SET ordinal = EXCLUDED.ordinal, operation = EXCLUDED.operation, " \
              "state = EXCLUDED.state WHERE #{snapshot}.ordinal < EXCLUDED.ordinal",
              [id, ordinal, state]
            )
          end
        end
      end
    end
  end
end
