require "yaml"

module Hecks
  module Fuzzing
    # Loads and validates `qa/settings.yml`, the hecks_qa dials.
    #
    # Fails loud: a missing key, unknown key or wrong-typed value raises at load time.
    # The meaning of each dial is documented on `QualityControlDials` in the bluebook.
    class QaSettings
      # Accessor name to the class (or classes) a valid value must be an instance of.
      # Booleans list both TrueClass and FalseClass; Numeric admits `0` as well as `0.0`.
      EXPECTED_TYPES = {
        cadence_seconds:              Integer,
        pr_cap_per_day:               Integer,
        widening_tiers:               Array,
        sweep_max_parallel:           Integer,
        liveness_fallback_seconds:    Integer,
        draft_only:                   [TrueClass, FalseClass],
        auto_merge:                   [TrueClass, FalseClass],
        branch_prefix:                String,
        adversarial_fraction:         Numeric,
        guided_generation:            [TrueClass, FalseClass],
        corpus_splice_probability:    Numeric,
        favor_rare_verbs:             Integer,
        self_consistency_checks:      [TrueClass, FalseClass],
        shrink_budget:                Integer,
        yield_weight_seconds:         Integer,
        yield_decay_percent:          Integer,
        rotation_stale_floor_seconds: Integer,
        persistence_parity_seed_cap:  Integer,
        concurrency_seed_cap:         Integer,
        adapter_parity_pairs:         Hash,
        modes:                        Hash,
        role_draw_probability:        Numeric,
        dry_run_fraction:             Numeric,
        generated_domains_per_tick:   Integer,
        generated_domains_rust:       [TrueClass, FalseClass],
        generated_domain_seeds:       Integer,
        structural_refusal_boundary:  Array
      }.freeze

      attr_reader(*EXPECTED_TYPES.keys)

      # The one real file, resolved from this file's `__dir__` rather than the bluebook's:
      # IsolatedBoot copies only `qa/bluebook`, so a bluebook-relative path would miss it.
      DEFAULT_PATH = File.expand_path("../../../qa/settings.yml", __dir__)

      class << self
        # Loads and validates `qa/settings.yml` (or `path`), returning a frozen instance.
        #
        # @param path [String] path to the YAML settings file; defaults to `DEFAULT_PATH`
        # @return [Hecks::Fuzzing::QaSettings] the validated, frozen settings
        # @raise [ArgumentError] if `path` does not exist, is not valid YAML, is not a
        #   YAML mapping at the top level, is missing a required key, declares an
        #   unknown key, or gives a value the wrong type for its dial
        def load(path = DEFAULT_PATH)
          raise ArgumentError, "qa settings file not found: #{path}" unless File.file?(path)

          raw = begin
            YAML.safe_load_file(path, symbolize_names: true)
          rescue Psych::SyntaxError => e
            raise ArgumentError, "#{path} is not valid YAML: #{e.message}"
          end
          raise ArgumentError, "#{path} must be a YAML mapping at the top level, got #{raw.class}" unless raw.is_a?(Hash)

          new(raw, path)
        end
      end

      # @param raw [Hash] parsed YAML settings keyed by symbol, one entry per dial in
      #   `EXPECTED_TYPES`
      # @param path [String] path to the settings file, used only in error messages
      # @raise [ArgumentError] if `raw` is missing a required key, declares an unknown
      #   key, or gives a value the wrong type for its dial
      def initialize(raw, path)
        missing = EXPECTED_TYPES.keys - raw.keys
        raise ArgumentError, "#{path} is missing #{missing.sort.join(', ')}" if missing.any?

        extra = raw.keys - EXPECTED_TYPES.keys
        if extra.any?
          raise ArgumentError,
                "#{path} declares unknown key(s) #{extra.sort.join(', ')} — " \
                "Hecks::Fuzzing::QaSettings::EXPECTED_TYPES doesn't recognise them"
        end

        EXPECTED_TYPES.each do |key, expected|
          value = raw.fetch(key)
          expected_classes = Array(expected)
          unless expected_classes.any? { |klass| value.is_a?(klass) }
            raise ArgumentError,
                  "#{path}: #{key} must be a #{expected_classes.map(&:name).join(' or ')}, " \
                  "got #{value.class} (#{value.inspect})"
          end

          instance_variable_set(:"@#{key}", value)
        end

        symbolize_adapter_parity_pairs!(path)
        freeze_values!
      end

      private

      # YAML cannot spell a Symbol value, and IsolatedBoot case-matches adapters by symbol.
      def symbolize_adapter_parity_pairs!(path)
        @adapter_parity_pairs = @adapter_parity_pairs.to_h do |mode, pair|
          unless pair.is_a?(Hash) && pair.key?(:left) && pair.key?(:right)
            raise ArgumentError,
                  "#{path}: adapter_parity_pairs.#{mode} must have both left and right, got #{pair.inspect}"
          end

          [mode, { left: pair[:left].to_sym, right: pair[:right].to_sym }]
        end
      end

      def freeze_values!
        EXPECTED_TYPES.each_key { |key| instance_variable_get(:"@#{key}").freeze }
        freeze
      end
    end
  end
end
