require_relative "../../../../runtime/registry"

module Hecksagain
  module Adapters
    class Postgres
      class Lineage
        module TailMerge
          # ── fork observability ─────────────────────────────────────────

          # Post-cut writes an old era made after the newer era was minted
          # — the divergence between the worlds, observable at any time.
          def diverged_count(old_era)
            cut = eras.find { |era| era[:ordinal] == old_era + 1 }&.dig(:watermark)
            return 0 unless cut

            @db.exec(
              "SELECT count(*) FROM #{quoted_journal} WHERE era = #{old_era.to_i} AND ordinal > #{cut.to_i}"
            )[0]["count"].to_i
          end

          # ── tail-merge ─────────────────────────────────────────────────
          #
          # The one deliberate command — it marks a business event (an app
          # retiring), never a shape change. One transaction: advance the
          # watermarks, rebuild the head so the tail interleaves by its
          # recorded global ordinal, append the declared winners, audit —
          # and roll the whole thing back on any refusal. Records touched
          # by both worlds since the cut refuse until each has an explicit
          # winner; resolution itself is append-only (the winner's state
          # re-enters as the newest row and wins structurally — originals
          # stay immutable).
          def merge_tail!(aggregates:, edges:, winners: {}, audit: nil)
            @db.exec("BEGIN")
            @db.exec("SET LOCAL lock_timeout = '10s'")
            @db.exec("SELECT pg_advisory_xact_lock(hashtext('hecks_eras:' || #{text_literal(@domain)}))")
            held = eras
            era = held.last[:ordinal]
            label = held.last[:label]
            if era == 1
              @db.exec("ROLLBACK")
              raise Runtime::WiringError, "nothing to merge — #{@domain} stands at era 1"
            end
            cut = held.last[:watermark].to_i
            tip = last_ordinal

            conflicts = aggregates.flat_map { |aggregate| conflict_ids(aggregate, edges, era, cut) }
            unresolved = conflicts.reject { |_, id| winners.key?(id) }
            unless unresolved.empty?
              @db.exec("ROLLBACK")
              raise Runtime::WiringError,
                    "cannot merge the tail of #{@domain}: touched by both worlds since the cut — " \
                    "#{unresolved.map { |storage, id| "#{storage}##{id}" }.sort.join(', ')}. " \
                    "Name each winner (--winner <id>=old or --winner <id>=new), then run bin/merge_tail again. " \
                    "A winner takes the WHOLE record — the aggregate is the consistency boundary, so the " \
                    "loser's edits are discarded even where they touched different attributes"
            end

            # the new world's pre-merge head states, captured before the
            # rebuild lets the tail interleave
            new_states = {}
            aggregates.each do |aggregate|
              winners.select { |_, side| side == "new" }.each_key do |id|
                row = @db.exec_params("SELECT state FROM #{quote(head_view(aggregate.storage_name))} WHERE id = $1", [id])
                new_states[id] = [aggregate.storage_name, row[0]["state"]] if row.ntuples.positive?
              end
            end

            @db.exec_params("UPDATE hecks_eras SET watermark = $2 WHERE domain = $1 AND ordinal > 1", [@domain, tip])
            aggregates.each do |aggregate|
              @db.exec("DROP VIEW IF EXISTS #{quote(head_view(aggregate.storage_name))}")
              @db.exec("DROP MATERIALIZED VIEW IF EXISTS #{quote(matview(aggregate.storage_name, era, label))}")
              # full: the watermarks just moved — every ancestor matview's
              # cut is stale, so there is nothing safe to layer on.
              compile_head!(aggregate, era, label, edges, full: true)
            end

            winners.each do |id, side|
              aggregates.each do |aggregate|
                state =
                  if side == "old"
                    row = @db.exec_params(
                      "SELECT state FROM #{quote(matview(aggregate.storage_name, era, label))} " \
                      "WHERE aggregate_id = $1 AND operation = 'save' ORDER BY ordinal DESC LIMIT 1",
                      [id]
                    )
                    row.ntuples.positive? ? row[0]["state"] : nil
                  else
                    new_states[id]&.first == aggregate.storage_name ? new_states[id][1] : nil
                  end
                next unless state

                @db.exec_params(
                  "INSERT INTO #{quoted_journal} (era, aggregate, aggregate_id, operation, state) " \
                  "VALUES ($1, $2, $3, 'save', $4)",
                  [era, aggregate.storage_name, id, state]
                )
              end
            end

            if audit
              violations = audit.call
              unless violations.empty?
                @db.exec("ROLLBACK")
                raise Runtime::WiringError,
                      "cannot merge the tail of #{@domain}: the audit refused —\n  - #{violations.join("\n  - ")}"
              end
            end

            @db.exec("COMMIT")
            true
          rescue PG::LockNotAvailable
            @db.exec("ROLLBACK") rescue nil
            raise Runtime::WiringError,
                  "cannot merge the tail of #{@domain}: another mint or merge holds the domain lock — " \
                  "waited 10s; try again shortly"
          rescue PG::Error => error
            @db.exec("ROLLBACK") rescue nil
            raise Runtime::WiringError, "cannot merge the tail of #{@domain}: #{error.message.strip}"
          end

          # Ids touched by BOTH worlds since the cut — the old world's
          # post-cut tail INTERSECTed with the new world's own writes.
          def conflict_ids(aggregate, edges, era, cut)
            names = names_by_era(aggregate, edges)
            olds = (1...era).map { |ancestor| text_literal(names[:storage][ancestor - 1]) }.join(", ")
            @db.exec(<<~SQL).map { |row| [aggregate.storage_name, row["aggregate_id"]] }
              SELECT aggregate_id FROM #{quoted_journal}
              WHERE era < #{era.to_i} AND aggregate IN (#{olds}) AND ordinal > #{cut.to_i}
              INTERSECT
              SELECT aggregate_id FROM #{quoted_journal}
              WHERE era = #{era.to_i} AND aggregate = #{text_literal(names[:storage][era - 1])}
            SQL
          end
        end
      end
    end
  end
end
