require "fileutils"
require "tmpdir"
require_relative "isolated_boot"
require_relative "invalid_value_generator"
require_relative "value_generator"
require_relative "sequence_generator/catalog"
require_relative "sequence_generator/picker"
require_relative "sequence_generator/step_builder"
require_relative "sequence_generator/outcome_tracker"
require_relative "sequence_generator/query_binding"
require_relative "sequence_generator/adversary"

module Hecks
  module Fuzzing
    # A random-but-valid sequence of dispatches and queries, in the `{name, note, steps}`
    # shape of `spec/corpus/*.json`, so a generated sequence replays as a corpus member.
    # Each step is dispatched for real against a throwaway boot while the sequence is built.
    class SequenceGenerator
      include Catalog
      include Picker
      include StepBuilder
      include OutcomeTracker
      include QueryBinding
      include Adversary

      # Creating commands are always eligible; weighting them up reaches an actionable
      # state sooner without starving domains that have few aggregates.
      CREATING_WEIGHT = 2

      # Low, because a refused step reaches no new state and a run of them is silent.
      MALFORMED_ARGUMENT_PROBABILITY = 0.12

      # A fair coin: an optional argument is legal present or absent. Separate from
      # `malform`, whose dropped required argument is refused and so never stores a null.
      OPTIONAL_OMITTED_PROBABILITY = 0.5

      # Preference for a verb this sequence has not yet dispatched, so whole commands
      # are not left untouched for a run.
      UNEXERCISED_WEIGHT = 4

      # Generates a random-but-valid step sequence for `domain_path`, dispatching each
      # step against a throwaway boot. Fractions at `0.0` draw nothing from the RNG.
      #
      # @param seed [Integer] RNG seed; every draw is reproducible from it
      # @param steps [Integer] number of generation attempts
      # @param adversarial [Float] fraction of command steps mutated adversarially
      # @param role_draw [Float] fraction of gated commands given a drawn caller
      # @param dry_run [Float] fraction of command steps dispatched as dry runs
      # @param prefix [Hash, nil] `{"seed", "steps", "favor", "prefix"}` replayed first
      # @param favor [Array<String>] verbs the picker weights up
      # @return [Array<Hash>] the generated steps
      def self.generate(domain_path, seed:, steps:, **)
        new(domain_path, seed: seed, steps: steps, **).call
      end

      # Coverage tuples reached (`[[attempt_index, tuple], ...]`) and every verb the
      # booted catalog offered, so a campaign can tell an unhit verb from a missing one.
      Trace = Struct.new(:steps, :coverage, :verbs, keyword_init: true)

      # Generates one sequence like `.generate`, also returning the coverage tuples and
      # verbs a campaign needs.
      #
      # @return [Trace] the generated steps, coverage tuples reached, and catalog verbs
      def self.trace(domain_path, seed:, steps:, **)
        generator = new(domain_path, seed: seed, steps: steps, **)
        Trace.new(steps: generator.call, coverage: generator.coverage, verbs: generator.verbs)
      end

      # Weight of a `favor:` verb; comparable to UNEXERCISED_WEIGHT so favor steers
      # without drowning out untouched verbs.
      FAVOR_WEIGHT = 4

      attr_reader :coverage, :verbs

      # Sum of every `Result#events` length across the run; hecks fuzz declares it as the
      # script's `expectations.events` claim. Zero means no interesting state was reached.
      attr_reader :event_count

      # Takes the same keywords as `.generate`, plus `adapter:` (default `:memory`).
      #
      # @raise [ArgumentError] if `adversarial`, `role_draw`, or `dry_run` is not a
      #   Numeric between 0.0 and 1.0
      def initialize(domain_path, seed:, steps:, adapter: :memory, adversarial: 0.0, role_draw: 0.0, dry_run: 0.0,
                     prefix: nil, favor: [])
        { adversarial: adversarial, role_draw: role_draw, dry_run: dry_run }.each do |name, fraction|
          next if fraction.is_a?(Numeric) && fraction.between?(0, 1)

          raise ArgumentError, "#{name}: must be a fraction between 0.0 and 1.0, got #{fraction.inspect}"
        end

        @domain_path         = domain_path
        @seed                = seed
        @step_count          = steps
        @adapter             = adapter
        @adversarial         = adversarial.to_f
        @role_draw           = role_draw.to_f
        @dry_run             = dry_run.to_f
        restart_random(seed)
        @known_ids           = Hash.new { |h, k| h[k] = [] }
        @entity_known_ids    = Hash.new { |h, k| h[k] = [] }
        @appended_identities = Hash.new { |h, k| h[k] = [] }
        # "Domain::Aggregate" => stored rows a query filters on (query_binding.rb).
        @written_rows        = Hash.new { |h, k| h[k] = [] }
        # Role => actor ids granted by this sequence's own `RoleAssignment.Assign` steps.
        @granted             = Hash.new { |h, k| h[k] = [] }
        @precedence_caller   = nil
        @exercised           = Set.new
        @event_count         = 0
        @prefix              = prefix
        @favor               = Array(favor)
        @own_favor           = @favor
        @coverage            = []
        @verbs               = []
        @attempt             = 0
      end

      # Runs the generation against a fresh, isolated boot of the domain.
      #
      # @return [Array<Hash>] the generated steps; a picker miss is dropped
      def call
        # Leftover data under the example's data/ would start the run from state
        # known_ids does not track; IsolatedBoot resets it and rebinds persistence to Memory.
        IsolatedBoot.call(@domain_path, adapter: @adapter) do |copy|
          runtime = Hecks.boot(copy, environment: nil)
          catalog = build_catalog(runtime)
          @verbs  = catalog.values_at(:creating, :instance, :entity_commands, :queries, :entity_queries, :read_models)
                           .flatten.map { |entry| entry[:verb] }.uniq

          steps = []
          if @prefix
            realize_prefix(runtime, catalog, @prefix, prefix_limit(@prefix), steps)
            restart_random(@seed)
            @favor = @own_favor
          end
          @step_count.times { steps << attempt_step(runtime, catalog) }
          steps.compact
        end
      end

      private

      # Re-runs the first `limit` attempts of another seed's generation (its own prefix
      # first), carrying its known ids and exercised verbs into this seed. The prefix is
      # on top of this seed's budget: taking it out of the budget left too little to explore.
      def realize_prefix(runtime, catalog, spec, limit, steps)
        return 0 unless limit.positive?

        inner = spec["prefix"]
        used  = inner ? realize_prefix(runtime, catalog, inner, [prefix_limit(inner), limit].min, steps) : 0
        restart_random(Integer(spec.fetch("seed")))
        @favor = Array(spec["favor"])
        (limit - used).times { steps << attempt_step(runtime, catalog) }
        limit
      end

      # Both streams restart together so a prefix replay draws the same query bindings.
      def restart_random(seed)
        @random         = Random.new(seed)
        @binding_random = Random.new(seed + QueryBinding::BINDING_SEED_OFFSET)
      end

      def prefix_limit(spec) = Integer(spec.fetch("steps")).clamp(0, @step_count)

      def attempt_step(runtime, catalog)
        index = @attempt
        @attempt += 1
        entry = pick(catalog)
        return nil unless entry

        @exercised << entry[:verb]
        @state_before = "-"
        step =
          if entry[:query]    then build_query_step(runtime, entry)
          elsif entry[:model] then build_read_model_step(runtime, entry)
          else                     build_command_step(runtime, catalog, entry)
          end
        @coverage << [index, coverage_tuple(entry, step)]
        step
      end

      # `verb | kind | state before | mutation | outcome`; see CoverageCampaign.
      def coverage_tuple(entry, step)
        kind     = %w[verb query dry_run].find { |key| step.key?(key) }
        mutation = Array(step["adversarial"]).map { |m| [m["mutation"], m["shape"]].compact.join(":") }.join("+")
        [entry[:verb], kind, @state_before, mutation.empty? ? "-" : mutation, @last_outcome].join(" | ")
      end
    end
  end
end
