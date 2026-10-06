# frozen_string_literal: true

require_relative "checks/engines"
require_relative "checks/seeds"
require_relative "checks/boundary"
require_relative "checks/shrinking"

module Hecks
  module QualityControlCli
    class QaSweep
      # The comparisons one sweep makes per seed, and the checks it logs for each. A sweep logs one
      # `Check` per mode per seed; the `[mode]` subject prefix tells the ledger which axis held or
      # surprised, and each expectation is written before looking.
      module Checks
        include Engines
        include Seeds
        include Boundary
        include Shrinking

        MODE_EXPECTATIONS = {
          differential:               "Ruby and the compiled Rust conformance binary agree on instances, events, refusals, " \
                                      "reactions, sagas, queries and dry runs across every generated step",
          properties_in_differential: "no declared property is violated over the Ruby side of the same " \
                                      "replayed history",
          self_consistency:           "each engine agrees with itself on rehydration/idempotency/value-object round trip",
          ruby_only:                  "no declared property is violated and the interpreter does not crash across every " \
                                      "generated step",
          persistence_parity:         "Memory and a real, disposable PostgresEra-backed boot agree on instances, " \
                                      "events, refusals, reactions, sagas and queries across every generated step",
          adapter_parity_sqlite:      "Memory and a real, on-disk SQLite-backed boot agree on instances, events, " \
                                      "refusals, reactions, sagas and queries across every generated step",
          concurrency:                "two real, forked, cross-process dispatches of the same generated command against " \
                                      "the same PostgresEra-backed schema settle on the same set of outcomes the identical " \
                                      "pair settles on when dispatched sequentially with no contention",
          era_boundary:               "no ancestor PostgresEra era this target's own real lineage holds still carries " \
                                      "post-cut writes nobody has merged forward (Lineage#diverged_count, every ancestor, " \
                                      "is zero)"
        }.freeze

        # Modes whose divergences are a pure function of the step list; a race, the per-sweep checks
        # and generator crashes are not.
        SHRINKABLE_MODES = %i[differential properties_in_differential self_consistency ruby_only
                              adapter_parity_sqlite persistence_parity].freeze

        private

        def log_check!(sweep, subject:, expectation:)
          sweep.check!(subject: { value: subject }, expectation: { value: expectation })
        end

        # `id:` addresses the Sweep; `sequence:` is the Check's own identity. The CLI's
        # to.aggregate=/to.entity= split is a CLI-layer translation, not what in-process dispatch
        # takes.
        def mark_held!(sweep, sequence, observation)
          @runtime.dispatch_flat("QualityControl::Sweep.Check.Held",
                                 { id: sweep.id, sequence: { value: sequence }, observation: { value: observation } })
        end

        # `target:` is what the SuspendOnSurprise policy reads; the target is suspended inside this
        # dispatch.
        def mark_surprised!(sweep, sequence, observation, target_reference)
          @runtime.dispatch_flat("QualityControl::Sweep.Check.Surprised",
                                 { id: sweep.id, sequence: { value: sequence }, observation: { value: observation },
                                   target: { value: target_reference } })
        end

        # Coverage-guided generation's corpus, one JSON file per (target, mode): `--all`'s waves can
        # run a target's primary sweep and its persistence-parity/concurrency variants as separate
        # `hecks quality_control query sweep.run` processes within the same tick, and each explores
        # a conceptually independent axis of the same domain, so each keeps its own file rather than
        # sharing one that nothing here locks.
        def coverage_corpus_path(target_reference, mode)
          File.join(@coverage_corpus_dir, "#{filesystem_safe_component(target_reference)}-#{mode}.json")
        end

        # Nil when nothing was ever saved for this (target, mode), or the file cannot be parsed;
        # either way the campaign starts from an empty corpus.
        def load_coverage_state(path)
          JSON.parse(File.read(path))
        rescue Errno::ENOENT, JSON::ParserError
          nil
        end

        def save_coverage_state!(path, campaign)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, JSON.pretty_generate(campaign.to_h))
        end
      end
    end
  end
end
