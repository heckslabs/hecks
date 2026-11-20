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
          # which reads the Rust binary's rehydration entry point under a differential seat.
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

          # Keeps a candidate only while its `Shrinker.signature` still contains the original's, and
          # times each candidate. A differential finding on served fields only is judged in
          # sessions of one warm kernel; anything else, as before, by a run of its own.
          def shrink_check(check, seat, steps)
            original = Hecks::Fuzzing::Shrinker.signature(check[:divergences])
            sessions, engine = shrink_engine(check[:mode], original)
            spent = [0.0]
            result = Hecks::Fuzzing::Shrinker.call(steps, budget: @shrink_budget) do |candidate|
              timed(spent) { candidate_reproduces?(original, [check[:mode], seat], sessions, candidate) }
            end
            shrunk_record(check, steps, result, engine, spent.first)
          ensure
            sessions&.close
          end

          # The sessions that judge this shrink and the name of the engine it runs on; a kernel
          # that will not serve falls back to a run per candidate, named with its reason.
          def shrink_engine(mode, original)
            servable = mode == :differential && @binary && Hecks::Fuzzing::Differential::ShrinkSessions.servable?(original)
            return [nil, "processes"] unless servable

            [Hecks::Fuzzing::Differential::ShrinkSessions.open(@binary, differ: @differ, domain_path: @domain_path),
             "sessions"]
          rescue Hecks::Fuzzing::Differential::ShrinkSessions::Unserved => e
            [nil, "processes (#{e.message})"]
          end

          # A raising candidate is a different finding, so it is rejected.
          def candidate_reproduces?(original, (mode, seat), sessions, candidate)
            divergences = sessions ? sessions.divergences(candidate) : candidate_divergences(mode, seat, candidate)
            Hecks::Fuzzing::Shrinker.reproduces?(original, divergences)
          rescue StandardError
            false
          end

          # Adds the seconds the block took to `spent[0]` and answers the block's value.
          def timed(spent)
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            yield
          ensure
            spent[0] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          end

          def shrunk_record(check, steps, result, engine, seconds)
            { mode: check[:mode], steps: result.steps, attempts: result.attempts, exhausted: result.exhausted,
              original_size: steps.size, engine: engine,
              seconds_per_candidate: result.attempts.zero? ? 0.0 : seconds / result.attempts }
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
