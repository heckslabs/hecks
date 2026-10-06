require_relative "../../../../../../runtime/registry"
require_relative "merge_writes"

module Hecks
  module Adapters
    class PostgresEra
      class Lineage
        # `merge_tail!` closes a fork: an old era's post-cut writes re-enter under named winners;
        # `diverged_count` measures the drift before that.
        module TailMerge
          include MergeWrites

          # What one merge works from: the aggregates and edge chain, the winners, and the era the
          # tail folds into with its label, cut and the journal's tip when the merge began.
          Merge = Data.define(:aggregates, :edges, :winners, :era, :label, :cut, :tip)

          # Counts the journal rows an old era wrote after the next era's cut.
          #
          # @return [Integer] 0 when the domain holds no newer era
          # @raise [Runtime::WiringError] if a held era's text fails its integrity check
          def diverged_count(old_era)
            cut = eras.find { |era| era[:ordinal] == old_era + 1 }&.dig(:watermark)
            return 0 unless cut

            @db.exec(
              "SELECT count(*) FROM #{quoted_journal} WHERE era = #{old_era.to_i} AND ordinal > #{cut.to_i}"
            )[0]["count"].to_i
          end

          # Folds every old era's post-cut writes into the current era's heads, under winners.
          #
          # One transaction; any refusal rolls back. Records both worlds touched need a winner.
          # One transaction with a manual `ROLLBACK` at each refusal, and the new world's head
          # states must be captured before the head rebuild; splitting the steps would scatter both.
          #
          # @param aggregates [Array<Bluebook::Aggregate>] the current bluebook's aggregates
          # @param edges [Array<Hash>] the mint-order edge chain, from `LineageManager.edge_chain`
          # @param winners [Hash{String => String}] aggregate id to `"old"` or `"new"`
          # @param audit [#call, nil] returns violations (Array<String>); run before `COMMIT`
          # @raise [Runtime::WiringError] at era 1, an unresolved conflict, audit or lock failure
          def merge_tail!(aggregates:, edges:, winners: {}, audit: nil)
            run_merge!(aggregates, edges, winners, audit)
            true
          rescue PG::LockNotAvailable
            rollback_quietly
            raise Runtime::WiringError, merge_lock_refusal
          rescue PG::Error => e
            rollback_quietly
            raise Runtime::WiringError, "cannot merge the tail of #{@domain}: #{e.message.strip}"
          end

          private

          def run_merge!(aggregates, edges, winners, audit)
            merge = begin_merge!(aggregates, edges, winners)
            refuse_unresolved_conflicts!(merge)
            new_states = pre_merge_states(merge)
            recompile_heads!(merge)
            reinsert_winners!(merge, new_states)
            refuse_audit_violations!(audit)
            @db.exec("COMMIT")
          end

          # Opens the transaction under the domain's era lock and reads where the merge stands.
          def begin_merge!(aggregates, edges, winners)
            lock_for_merge!
            latest = eras.last
            refuse_era_one!(latest[:ordinal])
            Merge.new(aggregates: aggregates, edges: edges, winners: winners, era: latest[:ordinal],
                      label: latest[:label], cut: latest[:watermark].to_i, tip: last_ordinal)
          end

          def lock_for_merge!
            @db.exec("BEGIN")
            @db.exec("SET LOCAL lock_timeout = '10s'")
            @db.exec("SELECT pg_advisory_xact_lock(hashtext('hecks_eras:' || #{text_literal(@domain)}))")
          end

          def refuse_era_one!(era)
            return unless era == 1

            @db.exec("ROLLBACK")
            raise Runtime::WiringError, "nothing to merge — #{@domain} stands at era 1"
          end

          def refuse_unresolved_conflicts!(merge)
            conflicts = merge.aggregates.flat_map { |aggregate| conflict_ids(aggregate, merge.edges, merge.era, merge.cut) }
            unresolved = conflicts.reject { |_, id| merge.winners.key?(id) }
            return if unresolved.empty?

            @db.exec("ROLLBACK")
            raise Runtime::WiringError, conflict_refusal(unresolved)
          end

          def conflict_refusal(unresolved)
            "cannot merge the tail of #{@domain}: touched by both worlds since the cut — " \
              "#{unresolved.map { |storage, id| "#{storage}##{id}" }.sort.join(", ")}. " \
              "Name each winner (--winner <id>=old or --winner <id>=new), then run hecks merge_tail again. " \
              "A winner takes the WHOLE record — the aggregate is the consistency boundary, so the " \
              "loser's edits are discarded even where they touched different attributes"
          end

          def refuse_audit_violations!(audit)
            return unless audit

            violations = audit.call
            return if violations.empty?

            @db.exec("ROLLBACK")
            raise Runtime::WiringError,
                  "cannot merge the tail of #{@domain}: the audit refused —\n  - #{violations.join("\n  - ")}"
          end

          def merge_lock_refusal
            "cannot merge the tail of #{@domain}: another mint or merge holds the domain lock — " \
              "waited 10s; try again shortly"
          end
        end
      end
    end
  end
end
