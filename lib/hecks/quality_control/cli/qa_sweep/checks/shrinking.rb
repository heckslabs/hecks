# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaSweep
      module Checks
        # The shrinking of a surprising step list to a smaller one that still surprises, and the
        # file the shrunk steps are written to.
        module Shrinking
          private

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
            File.write(path, JSON.pretty_generate(shrunk_document(shrunk, seed)))
            path
          end

          def shrunk_document(shrunk, seed)
            { name:  "#{@feature}-#{shrunk[:mode]}-shrunk",
              note:  "hecks quality_control ask run #{@sweep_reference} seed #{seed}, shrunk " \
                     "from #{shrunk[:original_size]} steps",
              steps: shrunk[:steps] }
          end
        end
      end
    end
  end
end
