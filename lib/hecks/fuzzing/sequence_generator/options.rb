# frozen_string_literal: true

require_relative "drive"

module Hecks
  module Fuzzing
    class SequenceGenerator
      # The keywords a generator is built with beyond its seed and step count: checked, then kept
      # as the settings a run reads. The defaults are `SequenceGenerator::OPTION_DEFAULTS`.
      module Options
        # The keywords that are fractions of steps, each between 0.0 and 1.0.
        FRACTIONS = %i[adversarial role_draw dry_run].freeze

        private

        def validate_options!(settings)
          unknown = settings.keys - SequenceGenerator::OPTION_DEFAULTS.keys
          raise ArgumentError, "unknown keyword: #{unknown.first.inspect}" if unknown.any?

          validate_engine!(settings[:engine])
          settings.slice(*FRACTIONS).each { |name, fraction| validate_fraction!(name, fraction) }
        end

        def validate_engine!(engine)
          return if Drive::ENGINES.include?(engine)

          raise ArgumentError, "engine: must be one of #{Drive::ENGINES.inspect}, got #{engine.inspect}"
        end

        def validate_fraction!(name, fraction)
          return if fraction.is_a?(Numeric) && fraction.between?(0, 1)

          raise ArgumentError, "#{name}: must be a fraction between 0.0 and 1.0, got #{fraction.inspect}"
        end

        def configure(settings)
          @adapter, @engine, @binary, @prefix = settings.values_at(:adapter, :engine, :binary, :prefix)
          @adversarial, @role_draw, @dry_run = settings.values_at(*FRACTIONS).map(&:to_f)
          @favor     = Array(settings[:favor])
          @own_favor = @favor
        end

        # The given binary, or the domain's Cargo feature built as `KernelEngine.boot` builds it.
        def kernel_binary
          @binary || RustBuild::KernelEngine.binary_for(RustBuild::KernelEngine.feature_of(@domain_path))
        end
      end
    end
  end
end
