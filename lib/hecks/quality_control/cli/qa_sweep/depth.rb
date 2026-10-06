# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaSweep
      # How deep a single-target sweep goes: seeds and steps from the target's clean streak, the
      # clamps on seeds, and the lines that announce the resolution.
      module Depth
        # Why `--seeds` is clamped for `--persistence-parity`.
        PARITY_CLAMP_REASON = "Real PostgresEra I/O per dispatch is genuinely expensive"

        # Why `--seeds` is clamped for `concurrency`.
        CONCURRENCY_CLAMP_REASON = "Each seed forks two real racers against real PostgresEra I/O"

        private

        # Read once after claiming: nothing before `Target.Release` changes `clean_streak`, and it
        # sizes this sweep and seeds `next_streak`.
        def resolve_depth
          @current_streak = @target.clean_streak.value
          default_seeds, default_steps = Hecks::Fuzzing::SweepDepth.for_streak(@current_streak, tiers: @widening_tiers)
          @seeds = @seeds_override || default_seeds
          @steps_per_sequence = @steps_override || default_steps

          # Only when depth is auto-resolved from the streak: an explicit `--seeds N` is a person's
          # manual debugging/reproduction run, and stays the predictable `1..N`. Growing this with
          # the streak is what keeps a matured target's sweep moving into seed integers it has
          # never generated before (see `Hecks::Fuzzing::SweepDepth.seed_offset`).
          @seed_offset = @seeds_override ? 0 : Hecks::Fuzzing::SweepDepth.seed_offset(@current_streak, default_seeds)
          clamp_seeds
        end

        # Clamps down (never up) only for `--persistence-parity`: real PostgresEra I/O per dispatch
        # is expensive even for a target on the widest tier. `concurrency` has a tighter cap: each
        # seed pays for two disposable schemas and a real fork; it is reached via `--modes
        # concurrency`.
        def clamp_seeds
          clamp_seeds_to(:PERSISTENCE_PARITY_SEED_CAP, PARITY_CLAMP_REASON) if @persistence_parity_mode
          clamp_seeds_to(:CONCURRENCY_SEED_CAP, CONCURRENCY_CLAMP_REASON) if @active_modes.include?(:concurrency)
        end

        def clamp_seeds_to(dial_name, reason)
          cap = ::QualityControlDials.const_get(dial_name)
          return unless @seeds > cap

          puts "note: --seeds #{@seeds} exceeds QualityControlDials::#{dial_name} (#{cap}) — clamping down. " \
               "#{reason}; edit that dial in qa/settings.yml to run more."
          @seeds = cap
        end

        def announce_resolution
          puts "resolved depth: seeds=#{@seeds} steps=#{@steps_per_sequence} (clean_streak=#{@current_streak})"
          puts "seed range: #{@seed_offset + 1}..#{@seed_offset + @seeds}" if @seeded_modes.any?
          line = "resolved modes: #{@active_modes.join(",")} (capabilities=#{@capabilities.join(",")}"
          line += "; deferred=#{@deferred_modes.join(",")}" unless @deferred_modes.empty?
          puts "#{line})"
        end
      end
    end
  end
end
