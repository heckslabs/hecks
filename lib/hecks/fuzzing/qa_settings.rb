require "yaml"

module Hecks
  module Fuzzing
    # READS `qa/settings.yml` — the hecks_qa practice's own dials, now
    # data in a file rather than Ruby constant literals. The WHY of each
    # dial (what it does, who reads it) stays exactly one place: the
    # comments on `QualityControlDials` in `qa/bluebook/quality_control.
    # bluebook`, which now sources every value from an instance of this
    # class instead of writing it inline. This class is only the loading
    # and the validation — no dial policy lives here.
    #
    # FAILS LOUD, NOT QUIET — the whole practice's own opening line
    # ("the enemy is the quiet divergence") applies to its own settings
    # file too: a missing key, an extra key nothing recognises, or a
    # value of the wrong shape all raise immediately, at load time
    # (which is bluebook-load time, i.e. `Hecks.boot`), naming exactly
    # what's wrong — never a `nil` dial silently reaching a script that
    # assumes a number.
    #
    # PLAIN DATA IN, FROZEN DATA OUT. `.load` parses the YAML with
    # `Psych.safe_load_file` (no custom tags, no arbitrary Ruby objects)
    # and hands back an instance whose accessors are the exact values a
    # human wrote in the file — a `Hash`/`Array` for the nested dials,
    # never a second, richer wrapper type nothing else in this practice
    # expects.
    class QaSettings
      # One entry per dial this class knows about: the accessor name
      # (matching `qa/settings.yml`'s own key, and `QualityControlDials`'
      # constant name snake_cased) mapped to the class (or classes) a
      # valid value must be an instance of. `TrueClass`/`FalseClass`
      # both name a boolean dial — Ruby has no single class both `true`
      # and `false` share. `Numeric` admits both an Integer and a Float
      # for a fraction dial (`0` and `0.0` are both a human plausibly
      # types for "off").
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

      # THE REAL FILE, ALWAYS — resolved off THIS file's own `__dir__`
      # (lib/hecks/fuzzing/), never off the caller's. `QualityControlDials`
      # is defined inside `qa/bluebook/quality_control.bluebook`, and that
      # exact directory gets COPIED to a tmpdir for every isolated/replayed
      # boot (`Hecks::Fuzzing::IsolatedBoot#copy_dereferencing` copies only
      # `qa/bluebook`'s own contents, never its parent `qa/`) — a path
      # resolved from the bluebook's own `__dir__` would silently point at
      # a copy with no `settings.yml` beside it at all. `qa/settings.yml`
      # is read-only, human-edited data with no lifecycle (see this class's
      # own header) — there is no isolation reason to ever read a COPY of
      # it, real boot or fuzzed one, so every caller gets the one real file
      # by default. `qa_settings_spec.rb` passes its own fixture paths
      # explicitly instead, the same way every other test in this practice
      # that needs a non-default dial passes one in rather than mutating
      # global state.
      DEFAULT_PATH = File.expand_path("../../../qa/settings.yml", __dir__)

      class << self
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

      # `left:`/`right:` name adapters `IsolatedBoot` case-matches by
      # SYMBOL (`case adapter when :memory ...`), and YAML has no way to
      # spell a bare Ruby Symbol as a mapping VALUE — only
      # `symbolize_names:` turns a KEY into one. So `adapter_parity_
      # pairs` is the one dial that needs a coercion step after the
      # type check above, rather than every dial growing one.
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
