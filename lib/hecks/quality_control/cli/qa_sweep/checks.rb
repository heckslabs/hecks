# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaSweep
      # The comparisons one sweep makes per seed, and the checks it logs for each. A sweep logs one
      # `Check` per mode per seed; the `[mode]` subject prefix tells the ledger which axis held or
      # surprised, and each expectation is written before looking.
      module Checks
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
          if modes.include?(:adapter_parity_sqlite)
            outcomes[:adapter_parity_sqlite] = adapter_parity_sqlite_divergences(domain_path, steps)
          end
          outcomes
        rescue StandardError => e
          # A crash is one mode's finding, not the absence of the others: each other enabled mode
          # gets an explicit not_checked entry so the ledger still holds one Check per resolved
          # mode.
          crashed = { ruby_only: [{ field: "crash", detail: "#{e.class}: #{e.message}" }] }
          %i[self_consistency adapter_parity_sqlite].each do |mode|
            next unless modes.include?(mode)

            crashed[mode] = [{ field:  "not_checked",
                               detail: "the Ruby replay crashed before #{mode} ran — #{e.class}: #{e.message}" }]
          end
          crashed
        end

        def log_check!(sweep, subject:, expectation:)
          sweep.check!(subject: { value: subject }, expectation: { value: expectation })
        end

        def check_for(mode, feature, seed, shape, divergences)
          { mode:        mode,
            subject:     "[#{mode}] #{feature} fuzz seed #{seed} (#{shape})",
            expectation: MODE_EXPECTATIONS.fetch(mode),
            divergences: divergences,
            clean:       divergences.empty?,
            observation: divergences.empty? ? "held" : "diverged on: #{divergences.map { |d| d[:field] }.join(', ')}" }
        end

        # Extra `generate` arguments a guided seed needs in its `reproduce:` line; empty when
        # unguided.
        def plan_arguments(plan)
          return "" unless plan

          parts = []
          parts << "prefix: #{plan.prefix.inspect}" if plan.prefix
          parts << "favor: #{plan.favor.inspect}" unless plan.favor.empty?
          parts.empty? ? "" : ", #{parts.join(', ')}"
        end

        # Once-per-sweep report of verbs skipped as not generated: held with the full list,
        # surprised if any skipped verb's construct is outside the documented boundary.
        def structural_skip_check(differ, binary, boundary)
          skipped = differ.structural_skips.to_a.sort
          gaps = Hecks::Fuzzing::RustGapManifest.for_binary(binary)
          attributed = Hecks::Fuzzing::StructuralSkips.attribute(gaps, skipped)
          outside = Hecks::Fuzzing::StructuralSkips.outside_boundary(attributed, boundary)
          listing = attributed.map { |e| "#{e[:verb]} [#{e[:constructs].join(',')}]" }.join("; ")
          divergences = outside.map do |e|
            declares = e[:constructs].empty? ? "nothing" : e[:constructs].join(",")
            { field: "structural_skip", verb: e[:verb], constructs: e[:constructs],
              detail: "#{e[:verb]} was skipped as not generated (construct: #{declares}), outside " \
                      "STRUCTURAL_REFUSAL_BOUNDARY — a codegen regression or a new gap, not a documented boundary" }
          end
          observation = if divergences.empty?
                          "all #{skipped.size} inside the documented boundary"
                        else
                          "#{divergences.size} outside the boundary"
                        end
          { mode: :structural_skip_report,
            subject: "[structural_skip_report] structurally skipped #{skipped.size} verb(s): [#{listing}]",
            expectation: "every named query/read model skipped because manifest.json declares it not " \
                         "generated names a construct inside QualityControlDials::STRUCTURAL_REFUSAL_BOUNDARY",
            divergences: divergences, clean: divergences.empty?, observation: observation }
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

        # Memory vs SQLite through the same `PersistenceParity.diff`, run inside the primary seat's
        # loop; an operational failure surfaces as a `process` finding.
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

        # Seedless, once per sweep: audits the target's own persisted lineage. Nothing to audit is a
        # note, not a finding.
        def era_boundary_check(domain_path)
          result = Hecks::Fuzzing::EraBoundary.diverged_ancestor_writes(domain_path)
          return unchecked_era_boundary(domain_path, result) unless result[:checked]

          divergences =
            if result[:diverged_total].positive?
              [{ field: "era_boundary", breakdown: result[:breakdown],
                 detail: "#{result[:diverged_total]} post-cut write(s) across #{result[:era_count]} era(s) " \
                         "that nothing has ever merged forward — hecks merge_tail <this target's own domain " \
                         "path> is the fix; see this script's own header on `era_boundary` for the class of " \
                         "bug this is" }]
            else
              []
            end

          { mode: :era_boundary, subject: "[era_boundary] #{File.basename(domain_path)} — ancestor-era audit " \
                                          "(#{result[:era_count]} era(s) on record)",
            expectation: MODE_EXPECTATIONS.fetch(:era_boundary), divergences: divergences,
            clean: divergences.empty?,
            observation: divergences.empty? ? "no ancestor era holds an unmerged write" : "#{result[:diverged_total]} diverged" }
        end

        # Nothing to audit and could not audit stay apart: `not_applicable` logs no `Check`, while
        # an error is a finding, so an unreachable database never counts as a held `Check` toward
        # the streak.
        def unchecked_era_boundary(domain_path, result)
          if result[:kind] == :not_applicable
            return { mode: :era_boundary, skip: true, observation: "not applicable — #{result[:reason]}" }
          end

          { mode: :era_boundary, subject: "[era_boundary] #{File.basename(domain_path)} — ancestor-era audit",
            expectation: MODE_EXPECTATIONS.fetch(:era_boundary),
            divergences: [{ field: "era_boundary_unchecked", detail: result[:reason] }], clean: false,
            observation: "could not audit — #{result[:reason]}" }
        end

        # Runs one seed under every active mode: `{ steps:, trace:, checks: }`, one check per mode;
        # logging is the loop's job. A generator crash is a finding too: a step broke the
        # interpreter before replay.
        def run_one_seed(seat, seed)
          shape = "#{@steps_per_sequence} steps, adversarial #{@adversarial}, role_draw #{@role_draw}, " \
                  "dry_run #{@dry_run}"
          plan = @campaign&.plan(seed)
          shape += ", spliced" if plan&.spliced?
          begin
            trace = Hecks::Fuzzing::SequenceGenerator.trace(
              @domain_path, seed: seed, steps: @steps_per_sequence, adversarial: @adversarial,
                            role_draw: @role_draw, dry_run: @dry_run, **(plan ? plan.generator_options : {})
            )
            steps = trace.steps
          rescue StandardError => e
            return { plan: plan, steps: [], checks: [generator_crash_check(seed, shape, e)] }
          end

          outcomes = seed_outcomes(seat, steps)
          { plan: plan, steps: steps, trace: trace,
            checks: outcomes.map { |mode_key, divergences| check_for(mode_key, @feature, seed, shape, divergences) } }
        end

        def generator_crash_check(seed, shape, error)
          { mode: :generator, subject: "[generator] #{@feature} fuzz seed #{seed} (#{shape}) — sequence generation",
            expectation: "SequenceGenerator builds every step without anything but a domain refusal escaping " \
                         "its own inline dispatch",
            divergences: [{ field:  "generator_crash",
                            detail: "#{error.class}: #{error.message}\n#{error.backtrace.first(6).join("\n")}" }],
            clean: false, observation: "generator crashed: #{error.class}: #{error.message}" }
        end

        def seed_outcomes(seat, steps)
          case seat
          when :differential then diff_ruby_vs_rust(@differ, @domain_path, steps, @binary, modes: @active_modes)
          when :persistence_parity
            { persistence_parity: persistence_parity_outcome(@domain_path, steps, @parity_database,
                                                             @parity_schema).last }
          when :concurrency
            { concurrency: concurrency_outcome(@domain_path, steps, @concurrency_database, @race_schema,
                                               @reference_schema) }
          else ruby_only_outcome(@domain_path, steps, modes: @active_modes)
          end
        end

        # Re-runs only the comparison that surprised; `seat` matters only for `self_consistency`,
        # which reads the Rust binary's rehydration door under a differential seat.
        def candidate_divergences(check_mode, seat, steps)
          case check_mode
          when :differential
            diff_ruby_vs_rust(@differ, @domain_path, steps, @binary, modes: [:differential])[:differential]
          when :properties_in_differential, :ruby_only
            ruby_only_outcome(@domain_path, steps, modes: [])[:ruby_only]
          when :self_consistency then self_consistency_candidate(seat, steps)
          when :adapter_parity_sqlite then adapter_parity_sqlite_divergences(@domain_path, steps)
          when :persistence_parity
            persistence_parity_outcome(@domain_path, steps, @parity_database, @parity_schema).last
          end || []
        end

        def self_consistency_candidate(seat, steps)
          if seat == :differential
            diff_ruby_vs_rust(@differ, @domain_path, steps, @binary, modes: [:self_consistency])[:self_consistency]
          else
            ruby_only_outcome(@domain_path, steps, modes: [:self_consistency])[:self_consistency]
          end
        end

        # Keeps a candidate only while its `Shrinker.signature` still contains the original's; a
        # raising candidate is a different finding, so it is rejected.
        def shrink_check(check, seat, steps)
          original = Hecks::Fuzzing::Shrinker.signature(check[:divergences])
          result = Hecks::Fuzzing::Shrinker.call(steps, budget: @shrink_budget) do |candidate|
            divergences = candidate_divergences(check[:mode], seat, candidate)
            Hecks::Fuzzing::Shrinker.reproduces?(original, divergences)
          rescue StandardError
            false
          end
          { mode: check[:mode], steps: result.steps, attempts: result.attempts, exhausted: result.exhausted,
            original_size: steps.size }
        end

        # Writes the shrunk steps in `hecks fuzz`'s `{name, note, steps}` shape so `hecks run` and
        # `hecks check_conformance` replay it unchanged.
        def write_shrunk!(shrunk, seed)
          dir = File.join(@root, "tmp/qa-shrunk")
          FileUtils.mkdir_p(dir)
          path = File.join(dir, "#{filesystem_safe_component(@sweep_reference)}-#{shrunk[:mode]}.json")
          File.write(path, JSON.pretty_generate(name:  "#{@feature}-#{shrunk[:mode]}-shrunk",
                                                note:  "hecks quality_control ask run #{@sweep_reference} seed #{seed}, shrunk " \
                                                       "from #{shrunk[:original_size]} steps",
                                                steps: shrunk[:steps]))
          path
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
