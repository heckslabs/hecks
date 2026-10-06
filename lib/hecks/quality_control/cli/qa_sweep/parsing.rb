# frozen_string_literal: true

require_relative "parsing/validation"

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
        include Validation

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
          reset_settings
          until argv.empty?
            arg = argv.shift
            return show_usage if %w[-h --help].include?(arg)

            parse_flag(arg, argv)
          end
          validate_arguments
          nil
        end

        def reset_settings
          @target_ref = @seeds_override = @steps_override = nil
          @all_mode = @persistence_parity_mode = @skip_parity_wave = @release_mode = false
          @adversarial = @self_consistency = @role_draw = @dry_run = nil
          # `--modes` (or its alias `--persistence-parity`); nil means the dial decides.
          @explicit_modes = nil
          @release_notes = nil
        end

        def show_usage
          puts USAGE
          :help
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
          when "--persistence-parity" then use_modes(%i[persistence_parity])
          when "--modes" then use_modes(parse_modes(argv.shift))
          when "--notes" then read_notes(argv.shift)
          when "--self-consistency" then @self_consistency = parse_boolean(arg, argv.shift)
          else record_target(arg)
          end
        end

        def use_modes(modes)
          @explicit_modes = modes
          @persistence_parity_mode = modes == %i[persistence_parity]
        end

        def read_notes(value)
          @release_notes = value
          abort "#{USAGE}\n--notes needs the text a person concluded" unless @release_notes
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
          abort "#{USAGE}\n--modes names no such mode: #{unknown.join(", ")} (known: #{known.join(", ")})" unless unknown.empty?

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
      end
    end
  end
end
