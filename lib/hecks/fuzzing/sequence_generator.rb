require "fileutils"
require "tmpdir"
require_relative "isolated_boot"
require_relative "invalid_value_generator"
require_relative "value_generator"
require_relative "sequence_generator/catalog"
require_relative "sequence_generator/picker"
require_relative "sequence_generator/step_builder"
require_relative "sequence_generator/outcome_tracker"
require_relative "sequence_generator/adversary"

module Hecks
  module Fuzzing
    # A random-but-valid sequence of dispatches and queries, in the exact
    # `{name, note, steps}` shape `spec/corpus/*.json` already uses — so a
    # generated sequence replays as a corpus member, completely unchanged.
    # Boots a throwaway copy of
    # the domain and dispatches each candidate step for real as it builds the
    # sequence (not just synthesizing plausible-looking JSON) : the only way to
    # know whether a step actually reached a new state, or which id an
    # auto-minted entity landed on, is to run it and watch what happened.
    #
    # Single-call fuzzing mostly misses the bugs this project has actually
    # found — they needed state first (a saga leg acting on a transfer that
    # already exists, a reference pointing at a customer already registered).
    # So this tracks what it has created as it goes, the same way
    # spec/banking_state_machine_spec.rb's hand-written generator does, and
    # weights later steps toward acting on what already exists.
    #
    # One concern per file beside this one: what the domain offers
    # (sequence_generator/catalog.rb), which step to try next (picker.rb),
    # how a step is built and dispatched (step_builder.rb), what a
    # success taught us (outcome_tracker.rb), and — opt-in, `adversarial:`
    # — the argument shapes real Ruby/Rust divergences were found through
    # (adversary.rb).
    class SequenceGenerator
      include Catalog
      include Picker
      include StepBuilder
      include OutcomeTracker
      include Adversary

      # Creating commands are always eligible ; weighting them heavier (not
      # exclusively — a domain with only one or two aggregates would starve
      # everything else) makes a sequence reach an actionable state sooner
      # instead of spending its early budget refusing "acts on nothing yet."
      CREATING_WEIGHT = 2

      # How often a payload is deliberately the wrong shape. Low, because a
      # refused step reaches no new state and a sequence of them is silent.
      MALFORMED_ARGUMENT_PROBABILITY = 0.12

      # How often an optional argument is simply not given — a fair coin,
      # because that is exactly what `optional:` means: present or absent,
      # both legal, neither the interesting case.
      #
      # This is not a malformation and must not be filed as one. `malform`
      # drops an argument too, but a dropped required argument is refused,
      # a refusal writes no record, and bin/fuzz counts it silent — so the
      # one outcome worth reaching (a stored record carrying a null, then
      # queried) was unreachable from that path by construction. Until
      # this existed no generated history contained a null at all, which
      # meant `query_answers_match_reference` — the differential that
      # diffs every native adapter against the reference interpreter — had
      # never once compared a nullable field. Four query bugs shipped in
      # exactly that blind spot (`ne:` with an empty string, array `in:`,
      # `ne:` against a null, `in` on a numeric field); the adapter
      # agreement gate had the identical hole and found a fourth bug the
      # hour it was closed.
      OPTIONAL_OMITTED_PROBABILITY = 0.5

      # How strongly an unexercised verb is preferred over one this sequence has
      # already dispatched. Random picking revisits the same handful of verbs and
      # leaves whole commands untouched for a whole run — which is the same
      # "reached no interesting state" problem the silent count reports, seen from
      # the generating end rather than the scoring end.
      UNEXERCISED_WEIGHT = 4

      # `adversarial:` — the fraction of generated command steps (0.0..1.0)
      # that get one deliberately adversarial argument mutation
      # (adversary.rb — the shapes BUG#7–#16 were found through). `0.0`,
      # the default, draws nothing extra from the seeded RNG, so a seed's
      # output is byte-for-byte what it was before the option existed;
      # any positive value is just as deterministic per seed, since every
      # choice the mutation makes comes from the same `Random.new(seed)`.
      #
      # `role_draw:` / `dry_run:` — two more opt-in fractions with the
      # identical contract (adversary.rb's `caller_draw!`, step_builder.rb's
      # `dry_run_draw?`): `0.0` draws nothing, so every pinned seed is
      # byte-for-byte what it was; `bin/qa_sweep` reads them from
      # `QualityControlDials::ROLE_DRAW_PROBABILITY`/`DRY_RUN_FRACTION`.
      #
      # `prefix:` / `favor:` — the two levers `CoverageCampaign` pulls
      # (coverage_campaign.rb has the why). `prefix:` is `{ "seed", "steps",
      # "favor", "prefix" }`: re-generate that seed's first `steps` attempts
      # (itself recursively prefixed) before this seed's own randomness
      # starts, so a seed can begin from state an earlier seed reached.
      # `favor:` names verbs the picker weights up. `nil`/`[]`, the
      # defaults, draw nothing extra and change nothing: every pinned seed
      # is byte-for-byte what it was.
      #
      # Generates one random-but-valid step sequence for `domain_path`, dispatching
      # each step for real against a throwaway boot as it builds it.
      #
      # @param domain_path [String] path to the domain directory to boot
      # @param seed [Integer] RNG seed; every draw this run makes is reproducible
      #   from it
      # @param steps [Integer] number of generation attempts to make
      # @param adapter [Symbol] persistence adapter to boot with (default `:memory`)
      # @param adversarial [Float] fraction of command steps to mutate adversarially
      #   (default `0.0`, drawing nothing extra)
      # @param role_draw [Float] fraction of gated commands to draw a caller for
      #   (default `0.0`, drawing nothing extra)
      # @param dry_run [Float] fraction of command steps dispatched as dry runs
      #   (default `0.0`, drawing nothing extra)
      # @param prefix [Hash, nil] another seed's own generation spec to replay
      #   first (`{"seed" =>, "steps" =>, "favor" =>, "prefix" =>}`), or `nil`
      # @param favor [Array<String>, Array<Symbol>] verbs the picker weights up
      # @return [Array<Hash>] the generated step list, each a command, query, or
      #   read-model step
      def self.generate(domain_path, seed:, steps:, **)
        new(domain_path, seed: seed, steps: steps, **).call
      end

      # The same generation, with what it reached — `coverage` is
      # `[[attempt_index, tuple], ...]` (`coverage_tuple`), `verbs` every
      # verb the booted catalog offered, so a campaign can tell a verb it
      # never hit from one that does not exist.
      Trace = Struct.new(:steps, :coverage, :verbs, keyword_init: true)

      # Generates one sequence exactly like `.generate`, but also returns the
      # coverage and verb data a campaign needs, which `.generate` discards.
      #
      # @param domain_path [String] path to the domain directory to boot
      # @param seed [Integer] RNG seed; every draw this run makes is reproducible
      #   from it
      # @param steps [Integer] number of generation attempts to make
      # @return [Hecks::Fuzzing::SequenceGenerator::Trace] the generated steps,
      #   the coverage tuples reached, and every verb the booted catalog offered
      def self.trace(domain_path, seed:, steps:, **)
        generator = new(domain_path, seed: seed, steps: steps, **)
        Trace.new(steps: generator.call, coverage: generator.coverage, verbs: generator.verbs)
      end

      # How strongly a `favor:` verb is preferred when it is eligible —
      # the same order of magnitude as an unexercised verb, so favor
      # steers without drowning out what this sequence has not touched.
      FAVOR_WEIGHT = 4

      attr_reader :coverage, :verbs

      # How many events the generated sequence actually produced — not
      # steps, not successful dispatches, but the sum of every Result#events
      # length across the run. This is the count bin/fuzz declares as the
      # script's own `expectations.events` claim: whatever was achieved
      # during generation becomes the claim a fresh replay of the same
      # script is held to. Zero means the sequence never
      # reached an interesting state — a fuzzer-effectiveness fact, not a
      # replay one.
      attr_reader :event_count

      # @param domain_path [String] path to the domain directory to boot
      # @param seed [Integer] RNG seed; every draw this run makes is reproducible
      #   from it
      # @param steps [Integer] number of generation attempts `#call` will make
      # @param adapter [Symbol] persistence adapter to boot with
      # @param adversarial [Float] fraction of command steps to mutate adversarially
      # @param role_draw [Float] fraction of gated commands to draw a caller for
      # @param dry_run [Float] fraction of command steps dispatched as dry runs
      # @param prefix [Hash, nil] another seed's own generation spec to replay
      #   first, or `nil`
      # @param favor [Array<String>, Array<Symbol>] verbs the picker weights up
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
        @random              = Random.new(seed)
        @known_ids           = Hash.new { |h, k| h[k] = [] }
        @entity_known_ids    = Hash.new { |h, k| h[k] = [] }
        @appended_identities = Hash.new { |h, k| h[k] = [] }
        # Role => [actor ids] this sequence's own successful
        # `Governance::RoleAssignment.Assign` steps granted — what the
        # `actor_known` caller shape draws from (adversary.rb).
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

      # Runs the generation this instance was configured for, against a fresh,
      # isolated boot of `@domain_path`.
      #
      # @return [Array<Hash>] the generated step list, each a command, query, or
      #   read-model step; a picker miss that produced no step is dropped
      def call
        # Real leftover data from ordinary use (bin/console, whatever) lives
        # under the example's data/ — a generator that boots against it
        # starts from state its own known_ids tracking doesn't know about.
        # IsolatedBoot resets that and rebinds persistence to Memory, since
        # a Postgres-bound domain's real store lives outside the copied
        # directory entirely and `rm_rf`ing data/ alone cannot reach it —
        # see isolated_boot.rb's own header.
        IsolatedBoot.call(@domain_path, adapter: @adapter) do |copy|
          runtime = Hecks.boot(copy)
          catalog = build_catalog(runtime)
          @verbs  = catalog.values_at(:creating, :instance, :entity_commands, :queries, :entity_queries, :read_models)
                           .flatten.map { |entry| entry[:verb] }.uniq

          steps = []
          if @prefix
            realize_prefix(runtime, catalog, @prefix, prefix_limit(@prefix), steps)
            @random = Random.new(@seed)
            @favor  = @own_favor
          end
          @step_count.times { steps << attempt_step(runtime, catalog) }
          steps.compact
        end
      end

      private

      # A prefix is the first `limit` attempts of another seed's generation,
      # re-run for real: its own nested prefix first (capped the same way it
      # was capped when that seed was generated), then that seed's own
      # `Random.new(seed)` and favor for the rest. Same inputs, same
      # catalog, same draws — the same steps, and the same known ids and
      # exercised verbs carried forward into this seed.
      #
      # The prefix is on top of this seed's own budget, not out of it. A
      # spliced seed still makes all `steps` attempts of its own after the
      # prefix; a prefix is capped at `steps` attempts, so a spliced
      # sequence is at most twice as long as an unspliced one. Taking the
      # prefix out of the budget (the first version of this) left a spliced
      # seed replaying state already seen with almost nothing left to
      # explore from it — measured: fewer distinct tuples than unguided.
      def realize_prefix(runtime, catalog, spec, limit, steps)
        return 0 unless limit.positive?

        inner = spec["prefix"]
        used  = inner ? realize_prefix(runtime, catalog, inner, [prefix_limit(inner), limit].min, steps) : 0
        @random = Random.new(Integer(spec.fetch("seed")))
        @favor  = Array(spec["favor"])
        (limit - used).times { steps << attempt_step(runtime, catalog) }
        limit
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

      # `verb | kind | state before | mutation | outcome` — see
      # CoverageCampaign's header for why the unit is this and not the
      # verb. `state` is the addressed aggregate's lifecycle value (or
      # `exists`/`absent` for one without a lifecycle) read just before
      # dispatch; `mutation` names every adversarial mutation and its shape;
      # `outcome` is `ok` or the refusal class `safe_call` rescued.
      def coverage_tuple(entry, step)
        kind     = %w[verb query dry_run].find { |key| step.key?(key) }
        mutation = Array(step["adversarial"]).map { |m| [m["mutation"], m["shape"]].compact.join(":") }.join("+")
        [entry[:verb], kind, @state_before, mutation.empty? ? "-" : mutation, @last_outcome].join(" | ")
      end
    end
  end
end
