# frozen_string_literal: true

require_relative "all_mode/children"
require_relative "all_mode/report"

module Hecks
  module QualityControlCli
    class QaSweep
      # `--all`: one child sweep per waiting target, in parallel, then the later waves and one
      # consolidated report.
      #
      # A child is a fresh process, never a fork: a forked child would share this process's live
      # Postgres socket.
      module AllMode
        include Children
        include Report

        # Said when no clean wave-1 target binds PostgresEra, so there is nothing to compare Memory
        # to.
        PARITY_WAVE_SKIPPED = "parity wave: no clean target binds PostgresEra — nothing to compare Memory " \
                              "against. Skipped."

        private

        # Sweeps every waiting target and reports.
        #
        # @param modes [Array<Symbol>] the enabled modes each child is told
        # @param parity_wave [Boolean] whether a `persistence_parity` wave follows a clean wave 1
        # @param deferred_wave_modes [Array<Symbol>] the modes that get a wave of their own
        # @return [Integer] 2 when any child found something, else 1 when any errored, else 0
        def run_all_mode(modes:, parity_wave:, deferred_wave_modes:)
          now = Time.now.to_i
          targets, stale = rotation_targets(now)
          return empty_rotation if targets.empty?

          announce_all(targets, stale, modes, now)
          started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          results = sweep_in_waves(targets, modes, parity_wave, deferred_wave_modes)
          report_all_mode(results, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at)
        end

        # @return [Array(Array<String>, Array<Hash>)] the references to sweep, and the stale holds
        #   among them
        def rotation_targets(now)
          waiting = query("Target.Rotation").map { |row| row[:reference][:value] }
          stale = stale_holds(now)
          [waiting + stale.map { |row| row[:reference][:value] }, stale]
        end

        def empty_rotation
          puts "rotation is empty — nothing waiting to sweep, and no stale hold to reclaim. Clean no-op."
          EXIT_OK
        end

        def announce_all(targets, stale, modes, now)
          puts "sweeping #{targets.size} target(s), at most #{@max_parallel} at once: #{targets.join(", ")} " \
               "(adversarial fraction #{@adversarial}, self-consistency #{@self_consistency}, " \
               "role draw #{@role_draw}, dry-run fraction #{@dry_run}, enabled modes #{modes.join(",")})"
          stale.each do |row|
            puts "reclaimed stale hold: #{row[:reference][:value]} (held by #{row[:held_by][:value]}, " \
                 "#{now - row[:claimed_at][:value]}s ago)"
          end
          puts
        end

        # `Target.Rotation` lists only waiting targets, so stale holds are found here:
        # `Target.Claim`'s given (claimed_at + window <= now) restated in Ruby, since a `where`
        # cannot add two fields.
        def stale_holds(now)
          query("Target.Held").select { |row| row[:claimed_at][:value] + row[:window][:value] <= now }
        end

        # Wave 1 over every target, then the parity wave and each deferred wave.
        def sweep_in_waves(targets, modes, parity_wave, deferred_wave_modes)
          flags = ChildFlags.new(@seeds_override, @steps_override, @self_consistency)
          results = run_pool(targets) { |reference| spawn_sweep_child(reference, flags, modes: modes) }
          results = results.map { |r| r.merge(wave: 1) }
          results += run_parity_wave(results) if parity_wave
          # Each enabled deferred mode gets its own wave over wave 1's clean targets.
          deferred_wave_modes.each do |mode|
            results += run_deferred_wave(results.select { |r| r[:wave] == 1 }, mode)
          end
          results
        end

        def report_all_mode(results, elapsed)
          clean = results.select { |r| r[:exit_status] == EXIT_OK }
          found = results.select { |r| r[:exit_status] == EXIT_FOUND_SOMETHING }
          errored = results.reject { |r| [EXIT_OK, EXIT_FOUND_SOMETHING].include?(r[:exit_status]) }
          print_all_mode_report(results, elapsed, clean, found, errored)
          all_mode_exit_code(found, errored)
        end

        # The flags of a later wave's children: the seeds override, no steps override, and no
        # self-consistency.
        def later_wave_flags
          ChildFlags.new(@seeds_override, nil, false)
        end

        # Wave 2: `--persistence-parity` children for wave-1 targets that came back clean and infer
        # `postgres_era`. Skipped by `--no-parity` or when `--modes` already named the mode.
        def run_parity_wave(wave1)
          candidates = wave_candidates(wave1, :persistence_parity)
          return skipped_wave(PARITY_WAVE_SKIPPED) if candidates.empty?

          puts
          puts "parity wave: Memory vs real PostgresEra for #{candidates.size} target(s), " \
               "at most #{@max_parallel} at once: #{candidates.join(", ")}"
          results = run_pool(candidates) do |reference|
            spawn_sweep_child(reference, later_wave_flags, modes: [], parity: true)
          end
          # Labelled in the target column so every report section tells a wave-2 row from wave 1's.
          results.map { |r| r.merge(wave: 2, target: "#{r[:target]} [parity wave]") }
        end

        # Later wave for deferred modes (era_boundary, concurrency): `--modes <mode>` children over
        # the clean wave-1 targets whose capabilities make the mode eligible.
        def run_deferred_wave(wave1, mode)
          candidates = wave_candidates(wave1, mode)
          return skipped_wave("#{mode} wave: no clean target qualifies. Skipped.") if candidates.empty?

          puts
          puts "#{mode} wave: #{candidates.size} target(s), at most #{@max_parallel} at once: #{candidates.join(", ")}"
          results = run_pool(candidates) do |reference|
            spawn_sweep_child(reference, later_wave_flags, modes: [mode])
          end
          results.map { |r| r.merge(wave: 2, target: "#{r[:target]} [#{mode} wave]") }
        end

        def skipped_wave(message)
          puts message
          []
        end

        # @return [Array<String>] the clean wave-1 targets whose capabilities make `mode` eligible
        def wave_candidates(wave1, mode)
          clean_refs = wave1.select { |r| r[:exit_status] == EXIT_OK }.map { |r| r[:target] }
          rows = query("Target.All").select { |row| clean_refs.include?(row[:reference][:value]) }
          rows.select { |row| eligible_for?(row, mode) }.map { |row| row[:reference][:value] }
        end

        def eligible_for?(row, mode)
          capabilities = Hecks::Fuzzing::TargetCapabilities.infer(resolve_target_path(row[:path][:value]),
                                                                  rust_dir: @rust_dir)
          Hecks::Fuzzing::TargetCapabilities.eligible?(mode, capabilities)
        end
      end
    end
  end
end
