# frozen_string_literal: true

module Hecks
  module QualityControlCli
    class QaSweep
      # The command line of `QaSweep`: every flag, and the rules for which combinations are refused.
      #
      # `seeds_override` and `steps_override` stay nil rather than a default, so an explicit
      # `--seeds 10` can be told apart from the streak-derived depth. The dials are read after the
      # ledger boots, so `adversarial`, `self_consistency`, `role_draw` and `dry_run` stay nil
      # until then.
      module Parsing
        # Each flag that reads a value, and the setting it fills.
        VALUE_SETTINGS = { "--role-draw" => :role_draw, "--dry-run" => :dry_run, "--adversarial" => :adversarial,
                           "--seeds" => :seeds_override, "--steps" => :steps_override }.freeze

        # Each flag that stands alone, and the setting it turns on.
        SWITCH_SETTINGS = { "--all" => :all_mode, "--no-parity" => :skip_parity_wave,
                            "--release" => :release_mode }.freeze

        private

        # Parses the flags into the instance's settings.
        #
        # @param argv [Array<String>] the command line's arguments, consumed
        # @return [Symbol, nil] `:help` once the usage is printed, else nil
        # @raise [SystemExit] with the usage when a flag or combination is refused
        def parse_arguments(argv)
          @target_ref = @seeds_override = @steps_override = nil
          @all_mode = @persistence_parity_mode = @skip_parity_wave = @release_mode = false
          @adversarial = @self_consistency = @role_draw = @dry_run = nil
          # `--modes` (or its alias `--persistence-parity`); nil means the dial decides.
          @explicit_modes = nil
          @release_notes = nil
          until argv.empty?
            arg = argv.shift
            if %w[-h --help].include?(arg)
              puts USAGE
              return :help
            end
            parse_flag(arg, argv)
          end
          validate_arguments
          nil
        end

        def parse_flag(arg, argv)
          if SWITCH_SETTINGS.key?(arg)
            instance_variable_set(:"@#{SWITCH_SETTINGS.fetch(arg)}", true)
          elsif VALUE_SETTINGS.key?(arg)
            parse_value_flag(arg, argv.shift)
          else
            parse_other_flag(arg, argv)
          end
        end

        def parse_value_flag(arg, value)
          setting = VALUE_SETTINGS.fetch(arg)
          parsed = %w[--seeds --steps].include?(arg) ? parse_integer(arg, value) : parse_fraction(arg, value)
          instance_variable_set(:"@#{setting}", parsed)
        end

        def parse_other_flag(arg, argv)
          case arg
          when "--persistence-parity"
            @persistence_parity_mode = true
            @explicit_modes = %i[persistence_parity]
          when "--modes"
            @explicit_modes = parse_modes(argv.shift)
            @persistence_parity_mode = @explicit_modes == %i[persistence_parity]
          when "--notes"
            @release_notes = argv.shift
            abort "#{USAGE}\n--notes needs the text a person concluded" unless @release_notes
          when "--self-consistency" then @self_consistency = parse_boolean(arg, argv.shift)
          else record_target(arg)
          end
        end

        def record_target(arg)
          abort "#{USAGE}\nunexpected argument: #{arg.inspect} (target already given: #{@target_ref.inspect})" if @target_ref

          @target_ref = arg
        end

        def parse_modes(value)
          names = value.to_s.split(",").map(&:strip).reject(&:empty?).map(&:to_sym)
          abort "#{USAGE}\n--modes needs at least one mode name" if names.empty?

          known = Hecks::Fuzzing::TargetCapabilities::MODE_REQUIREMENTS.keys
          unknown = names - known
          abort "#{USAGE}\n--modes names no such mode: #{unknown.join(', ')} (known: #{known.join(', ')})" unless unknown.empty?

          names
        end

        def parse_fraction(flag, value)
          abort "#{USAGE}\n#{flag} needs a fraction between 0 and 1" unless value

          fraction = begin
            Float(value)
          rescue ArgumentError
            abort "#{USAGE}\n#{flag} must be a number, got #{value.inspect}"
          end
          abort "#{USAGE}\n#{flag} must be between 0 and 1, got #{value}" unless fraction.between?(0, 1)
          fraction
        end

        def parse_integer(flag, value)
          abort "#{USAGE}\n#{flag} needs a number" unless value

          begin
            Integer(value)
          rescue ArgumentError
            abort "#{USAGE}\n#{flag} must be an integer, got #{value.inspect}"
          end
        end

        def parse_boolean(flag, value)
          abort "#{USAGE}\n#{flag} needs true or false" unless value

          case value
          when "true" then true
          when "false" then false
          else abort "#{USAGE}\n#{flag} must be true or false, got #{value.inspect}"
          end
        end

        def validate_arguments
          if @seeds_override && @seeds_override < 1
            abort "#{USAGE}\n--seeds must be at least 1 — Sweep.Conclude refuses a sweep that checked nothing"
          end
          abort "#{USAGE}\n--steps must be at least 1" if @steps_override && @steps_override < 1
          if @all_mode && @target_ref
            abort "#{USAGE}\n--all sweeps every waiting target itself — it does not take a target-reference " \
                  "(got #{@target_ref.inspect})"
          end

          # `--all --persistence-parity` forces the parity wave on; narrowing every child to that
          # one mode would abort each ineligible target. A single named target still narrows to that
          # mode.
          @force_parity_wave = @all_mode && @persistence_parity_mode
          if @force_parity_wave
            @persistence_parity_mode = false
            @explicit_modes = nil
          end
          validate_parity_and_release
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
