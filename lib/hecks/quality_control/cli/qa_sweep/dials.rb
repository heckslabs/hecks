# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaSweep
      # The dials a sweep reads once the ledger has booted, and the modes they enable. A dial-less
      # fixture ledger falls back to a sweep with the adversarial layer off and self-consistency on.
      module Dials
        private

        def dial(name, fallback)
          ::QualityControlDials.const_defined?(name, false) ? ::QualityControlDials.const_get(name) : fallback
        rescue NameError
          fallback
        end

        # Dials are read after boot because the bluebook defines them; a dial-less fixture ledger
        # runs the adversarial layer off and self-consistency on.
        def read_dials
          @adversarial ||= dial(:ADVERSARIAL_FRACTION, 0.0).to_f
          # Remembered before defaulting: the alias below applies only when the flag was typed, so
          # an explicit `--modes ruby_only` stays exclusive.
          @self_consistency_explicit = !@self_consistency.nil?
          @self_consistency = dial(:SELF_CONSISTENCY_CHECKS, true) if @self_consistency.nil?
          # Same off-without-a-dial default as the adversarial layer.
          @role_draw ||= dial(:ROLE_DRAW_PROBABILITY, 0.0).to_f
          @dry_run ||= dial(:DRY_RUN_FRACTION, 0.0).to_f
          # The loop's identity: `held_by` on claims, `engineer` on sweeps, and the literal
          # `WaivedBy` refuses.
          @engineer = dial(:AUTOMATED_ENGINEER, "qa_sweep")
          @widening_tiers = dial(:WIDENING_TIERS, Hecks::Fuzzing::SweepDepth::DEFAULT_TIERS)
          @guided_generation = dial(:GUIDED_GENERATION, false)
          @corpus_splice_probability = dial(:CORPUS_SPLICE_PROBABILITY, 0.5)
          @favor_rare_verbs = dial(:FAVOR_RARE_VERBS, 3)
          @max_parallel = dial(:SWEEP_MAX_PARALLEL, 4)
          @shrink_budget = dial(:SHRINK_BUDGET, 200)
          @structural_boundary = dial(:STRUCTURAL_REFUSAL_BOUNDARY, [])
          # The adapter pair each parity mode compares; a new pairing is a data change here, not a
          # new diff.
          @adapter_parity_pairs = dial(:ADAPTER_PARITY_PAIRS,
                                       { persistence_parity:    { left: :memory, right: :postgres_era },
                                         adapter_parity_sqlite: { left: :memory, right: :sqlite } }.freeze)
        end

        # `--modes` wins outright; otherwise the dial's enabled modes. `--self-consistency` adjusts
        # the set only when typed or when `--modes` was not given, so an explicit `--modes a,b`
        # stays exact.
        def resolve_enabled_modes
          @enabled_modes = @explicit_modes || dial_modes
          if @self_consistency_explicit || @explicit_modes.nil?
            @enabled_modes = if @self_consistency
                               @enabled_modes | [:self_consistency]
                             else
                               @enabled_modes - [:self_consistency]
                             end
          end
          # `--all --persistence-parity` forces the wave on regardless of the dial.
          @enabled_modes |= [:persistence_parity] if @force_parity_wave

          # Refuse modes with no implementation before claiming, so `resolved modes:` never
          # advertises coverage nobody wrote.
          unrunnable = @enabled_modes - Hecks::Fuzzing::TargetCapabilities::RUNNABLE_MODES
          return if unrunnable.empty?

          abort "enabled mode(s) #{unrunnable.join(",")} have no implementation in hecks quality_control ask run " \
                "(Hecks::Fuzzing::TargetCapabilities::RUNNABLE_MODES is what exists). Set them false in " \
                "qa/settings.yml, or drop them from --modes, until the code lands."
        end

        def dial_modes
          return DEFAULT_MODES unless ::QualityControlDials.const_defined?(:MODES, false)

          ::QualityControlDials::MODES.select { |_, on| on }.keys
        rescue NameError
          DEFAULT_MODES
        end

        # `--no-parity` skips every later wave. A mode gets a wave only when the dial enabled it and
        # `--modes` did not narrow the run.
        def deferred_waves
          %i[era_boundary concurrency].select do |mode|
            !@skip_parity_wave && @explicit_modes.nil? && @enabled_modes.include?(mode)
          end
        end

        def parity_wave?
          !@skip_parity_wave && @explicit_modes.nil? && @enabled_modes.include?(:persistence_parity)
        end
      end
    end
  end
end
