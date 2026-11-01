# frozen_string_literal: true

require_relative "../../../../../quality_control/adapters/qa_auto_mint"

module Hecks
  module Adapters
    class JournalStore
      module Readings
        module MintPlan
          # The watermark the mint reads and the freshness of a rehearsal against it, by the mint's
          # own rule (`QaAutoMint.stale_watermark`): the ledger may move only by the run's own
          # `Maintenance` record, counted by `Lineage#rows_of_after`.
          class WatermarkGuards
            RECORDED = <<~SQL
              SELECT payload->>'watermark' AS watermark, payload->'rehearsal_verdict'->>'value' AS verdict
              FROM events
              WHERE name IN ('RehearsalVerdict', 'MintRequested')
                AND (payload->>'rehearsal_ref' = $1 OR payload->'run'->>'value' = $1 OR aggregate_id = $1)
              ORDER BY id DESC LIMIT 1
            SQL
            RULE = "the mint refuses when the ledger moved by anything but the run's own Maintenance record"

            # @param report [Report] where each guard is recorded
            # @param db [PG::Connection] the read-only connection
            # @param lineage [Lineage] a read-only lineage over the store
            def initialize(report, db, lineage)
              @report = report
              @db = db
              @lineage = lineage
            end

            # @return [Integer] the live watermark, which is the `watermark=` the mint call takes
            def live
              @live ||= @lineage.last_ordinal
            end

            # Records the live watermark and, when a rehearsal ref is given, whether that rehearsal
            # is stale.
            #
            # @param ref [String, nil] the rehearsal's run id
            # @param watermark [Integer, nil] the watermark that rehearsal read
            # @param verdict [String, nil] the verdict that rehearsal gave, when the caller has it
            # @return [void]
            def call(ref: nil, watermark: nil, verdict: nil)
              @report.add("watermark", :info, "live watermark #{live}; pass watermark=#{live}; #{RULE}")
              return unless ref

              @report.check("rehearsal_ref") { rehearsal(ref, watermark, verdict) }
            end

            private

            def rehearsal(ref, watermark, verdict)
              watermark, verdict = recorded(ref) if watermark.nil? || verdict.nil?
              return [:refuse, unknown(ref)] if watermark.nil?
              return [:refuse, "rehearsal #{ref} said #{verdict.inspect}, not would_mint"] unless verdict == "would_mint"

              freshness(ref, watermark)
            end

            def freshness(ref, watermark)
              own = @lineage.rows_of_after(watermark, "maintenance", ref)
              stale = QaAutoMint.stale_watermark(watermark, live, own_rows: own)
              return [:refuse, stale] if stale

              [:pass, "rehearsal #{ref} read watermark #{watermark}; #{own} row(s) above it are the run's own record"]
            end

            def unknown(ref)
              "no record of rehearsal #{ref}: a rehearsal is kept by the process that ran it; pass " \
                "rehearsal_watermark= and rehearsal_verdict= from its answer"
            end

            # The verdict and watermark of a rehearsal the ledger recorded, or a mint that took it.
            def recorded(ref)
              return [nil, nil] unless @db.exec("SELECT to_regclass('events')").getvalue(0, 0)

              row = @db.exec_params(RECORDED, [ref]).first
              row ? [row["watermark"]&.to_i, row["verdict"]] : [nil, nil]
            end
          end
        end
      end
    end
  end
end
