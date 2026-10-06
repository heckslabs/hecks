# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaSweep
      module Parsing
        # The rules for which `QaSweep` flag combinations are refused once every flag is read.
        module Validation
          private

          def validate_arguments
            validate_depth_overrides
            validate_all_mode
            force_parity_wave
            validate_parity_and_release
          end

          def validate_depth_overrides
            if @seeds_override && @seeds_override < 1
              abort "#{USAGE}\n--seeds must be at least 1 — Sweep.Conclude refuses a sweep that checked nothing"
            end
            abort "#{USAGE}\n--steps must be at least 1" if @steps_override && @steps_override < 1
          end

          def validate_all_mode
            return unless @all_mode && @target_ref

            abort "#{USAGE}\n--all sweeps every waiting target itself — it does not take a target-reference " \
                  "(got #{@target_ref.inspect})"
          end

          # `--all --persistence-parity` forces the parity wave on; narrowing every child to that
          # one mode would abort each ineligible target. A single named target still narrows to that
          # mode.
          def force_parity_wave
            @force_parity_wave = @all_mode && @persistence_parity_mode
            return unless @force_parity_wave

            @persistence_parity_mode = false
            @explicit_modes = nil
          end

          def validate_parity_and_release
            if @persistence_parity_mode && !@target_ref
              abort "#{USAGE}\n--persistence-parity needs an explicit target-reference — it never auto-picks " \
                    "from the rotation, since only a PostgresEra-bound domain gains anything from this " \
                    "comparison at all (`resolved modes:` on any single-target run says whether a target qualifies)"
            end
            validate_release if @release_mode
            abort "#{USAGE}\n--notes only means something with --release" if @release_notes && !@release_mode
          end

          def validate_release
            unless @target_ref
              abort "#{USAGE}\n--release needs an explicit target-reference — the suspended target a person is " \
                    "putting back"
            end
            unless @release_notes
              abort "#{USAGE}\n--release needs --notes — what a person concluded is the one thing this script " \
                    "cannot supply"
            end
            return unless @all_mode || @persistence_parity_mode

            abort "#{USAGE}\n--release is its own mode — it does not combine with --all or --persistence-parity"
          end
        end
      end
    end
  end
end
