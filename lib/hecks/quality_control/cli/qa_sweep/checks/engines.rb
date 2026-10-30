# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaSweep
      module Checks
        # What each comparison engine says about one step list: the Ruby-vs-Rust diff, the
        # Ruby-only fallback, and the Memory-vs-Postgres, Memory-vs-SQLite and concurrent-dispatch
        # comparisons.
        module Engines
          private

          # Flattens Replay's `:self_consistency` results into the same `{field:, detail:}` shape as
          # every finding.
          def self_consistency_divergences(history) = Hecks::Fuzzing::Differential.self_consistency_divergences(history)

          def property_divergences(history) = Hecks::Fuzzing::Differential.property_divergences(history)

          # The Ruby-vs-Rust diff from `spec/rust_conformance_fuzz_spec.rb`, one divergence list per
          # active mode so `run_one_seed` logs a `Check` per mode.
          def diff_ruby_vs_rust(differ, domain_path, steps, binary, modes:)
            Hecks::Fuzzing::Differential.diff(
              differ, domain_path, steps, binary,
              modes: modes, adapter_parity_sqlite: -> { adapter_parity_sqlite_divergences(domain_path, steps) }
            )
          end

          # Single-runtime fallback (`hecks fuzz`'s `outcome`) for domains with no compiled Rust
          # binary: a violated property, or an exception escaping `Replay.call`.
          def ruby_only_outcome(domain_path, steps, modes:)
            self_consistency = modes.include?(:self_consistency)
            history = Hecks::Fuzzing::Replay.call(domain_path, steps, self_consistency: self_consistency)
            outcomes = { ruby_only: property_divergences(history) }
            outcomes[:self_consistency] = self_consistency_divergences(history) if self_consistency
            outcomes.merge(sqlite_outcome(domain_path, steps, modes))
          rescue StandardError => e
            crashed_outcomes(modes, e)
          end

          def sqlite_outcome(domain_path, steps, modes)
            return {} unless modes.include?(:adapter_parity_sqlite)

            { adapter_parity_sqlite: adapter_parity_sqlite_divergences(domain_path, steps) }
          end

          # A crash is one mode's finding, not the absence of the others: each other enabled mode
          # gets an explicit not_checked entry so the ledger still holds one Check per resolved
          # mode.
          def crashed_outcomes(modes, error)
            crashed = { ruby_only: [{ field: "crash", detail: "#{error.class}: #{error.message}" }] }
            %i[self_consistency adapter_parity_sqlite].each do |mode|
              next unless modes.include?(mode)

              crashed[mode] = [{ field:  "not_checked",
                                 detail: "the Ruby replay crashed before #{mode} ran — #{error.class}: #{error.message}" }]
            end
            crashed
          end

          # One `PersistenceParity.diff` per seed against this sweep's disposable schema. A
          # `PG::Error` or `WiringError` escaping it is a crash finding, never swallowed.
          def persistence_parity_outcome(domain_path, steps, database, schema)
            pair = @adapter_parity_pairs.fetch(:persistence_parity)
            divergences = Hecks::Fuzzing::PersistenceParity.diff(domain_path, steps, left: pair.fetch(:left),
                                                                                     right: pair.fetch(:right),
                                                                                     database: database, schema: schema)
            [divergences.empty? ? :clean : :divergence, divergences]
          rescue StandardError => e
            [:crash, [{ field: "process", detail: "#{e.class}: #{e.message}" }]]
          end

          # Memory vs SQLite through the same `PersistenceParity.diff`, run inside the primary
          # seat's loop; an operational failure surfaces as a `process` finding.
          def adapter_parity_sqlite_divergences(domain_path, steps)
            pair = @adapter_parity_pairs.fetch(:adapter_parity_sqlite)
            Hecks::Fuzzing::PersistenceParity.diff(domain_path, steps, left: pair.fetch(:left), right: pair.fetch(:right))
          rescue StandardError => e
            [{ field: "process", detail: "#{e.class}: #{e.message}" }]
          end

          # `ConcurrentDispatch.check` already returns the flat divergence shape and rescues to a
          # `process` finding; `[]` means the sequence had no command step to race.
          def concurrency_outcome(domain_path, steps, database, race_schema, reference_schema)
            Hecks::Fuzzing::ConcurrentDispatch.check(domain_path, steps, database:         database,
                                                                         race_schema:      race_schema,
                                                                         reference_schema: reference_schema)
          end
        end
      end
    end
  end
end
