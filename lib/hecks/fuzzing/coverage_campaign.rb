module Hecks
  module Fuzzing
    # Remembers which (verb, kind, state, mutation, outcome) tuples a sweep has reached.
    # Later seeds splice corpus prefixes and favor rarely hit verbs.
    #
    # Reproducible: the only randomness is `Random.new(seed)`, and each `Plan` is printable.
    class CoverageCampaign
      # One seed's generation instructions, printable and reproducible.
      Plan = Struct.new(:prefix, :favor, keyword_init: true) do
        # The keyword arguments `SequenceGenerator.generate` and `.trace` accept.
        def generator_options = { prefix: prefix, favor: favor }

        def spliced? = !prefix.nil?
      end

      attr_reader :corpus

      # @param splice_probability [Float] chance, per seed with a non-empty corpus, of splicing
      # @param favor_count [Integer] rare verbs to favor per plan; zero or less disables favoring
      # @param corpus_limit [Integer] entries kept; the oldest is dropped past this
      # @param max_prefix_depth [Integer] nested-prefix depth beyond which entries are not admitted
      def initialize(splice_probability:, favor_count:, corpus_limit: 64, max_prefix_depth: 6)
        @splice_probability = splice_probability.to_f
        @favor_count        = favor_count.to_i
        @corpus_limit       = corpus_limit
        @max_prefix_depth   = max_prefix_depth
        @corpus             = []
        @seen               = Set.new
        @runtime_seen       = Set.new
        @verb_hits          = Hash.new(0)
        @declared_verbs     = Set.new
        @seeds = @spliced = @seeds_with_new = 0
      end

      # Builds this seed's plan: a possible corpus splice, plus the verbs to favor.
      #
      # @param seed [Integer] drives the splice coin flip, the corpus entry and the prefix length
      # @return [Fuzzing::CoverageCampaign::Plan]
      def plan(seed)
        random = Random.new(seed)
        prefix = nil
        prefix = splice_prefix(random) if !@corpus.empty? && random.rand < @splice_probability
        Plan.new(prefix: prefix, favor: rare_verbs)
      end

      # Folds one seed's trace into the running coverage; admits a corpus entry if it reached
      # a new tuple, or, when `runtime` is given, a new runtime line or branch.
      #
      # @param seed [Integer] the seed the trace was generated from
      # @param plan [Fuzzing::CoverageCampaign::Plan] the plan that seed ran with
      # @param trace [Fuzzing::SequenceGenerator::Trace] from `SequenceGenerator.trace`
      # @param runtime [Enumerable<String>, nil] keys from `RuntimeCoverage.measure`; nil when
      #   runtime feedback is off, which leaves admission to tuples alone
      # @return [void]
      def record(seed, plan, trace, runtime: nil)
        tally(plan, trace)
        new_at = new_tuple_steps(trace)
        fresh_runtime = new_runtime?(runtime)
        return if new_at.empty? && !fresh_runtime

        @seeds_with_new += 1
        # A tuple cuts the entry at the step that reached it; a runtime key is not tied to a step,
        # so a seed that reached only new runtime keeps its whole sequence.
        admit(seed, plan, new_at.empty? ? [trace.steps.size, 1].max : new_at.max + 1)
      end

      # The number of distinct runtime lines and branches reached so far; zero while runtime
      # feedback is off.
      def runtime_seen = @runtime_seen.size

      # The number of distinct coverage tuples reached so far.
      def tuples_seen = @seen.size

      # One line of running totals: tuples seen, seeds run, seeds with new coverage, splices.
      def summary
        runtime = @runtime_seen.empty? ? "" : " and #{@runtime_seen.size} runtime line/branch key(s)"
        "coverage: #{@seen.size} distinct (verb, kind, state, mutation, outcome) tuple(s)#{runtime} over " \
          "#{@seeds} seed(s); #{@seeds_with_new} seed(s) reached something new; " \
          "#{@spliced} spliced from a corpus of #{@corpus.size}"
      end

      # Serializes the accumulated corpus and coverage knowledge, JSON-safe, so a later process can
      # pick this campaign up where it left off. This campaign's own dials — splice probability,
      # favor count, corpus and prefix-depth bounds — are configuration a caller supplies fresh each
      # time, not state, so they are not part of this.
      #
      # @return [Hash] with string keys "corpus", "seen", "runtime_seen", "verb_hits" and
      #   "declared_verbs"
      def to_h
        { "corpus"         => @corpus.map { |entry| { "spec" => entry[:spec], "attempts" => entry[:attempts] } },
          "seen"           => @seen.to_a,
          "runtime_seen"   => @runtime_seen.to_a.sort,
          "verb_hits"      => @verb_hits.dup,
          "declared_verbs" => @declared_verbs.to_a }
      end

      # Replaces this campaign's accumulated corpus and coverage knowledge with what a prior
      # campaign's `#to_h` serialized, leaving this campaign's own dials untouched.
      #
      # @param state [Hash] as `#to_h` produced it; string or symbol keys both accepted
      # @return [void]
      def restore!(state)
        state = state.transform_keys(&:to_s)
        @corpus = Array(state["corpus"]).map { |entry| { spec: entry["spec"], attempts: entry["attempts"] } }
        @seen, @runtime_seen, @declared_verbs = %w[seen runtime_seen declared_verbs].map { |key| Set.new(Array(state[key])) }
        @verb_hits = Hash.new(0).merge(state["verb_hits"] || {})
      end

      # Builds a campaign that already knows what a prior campaign's `#to_h` reached, configured
      # with this process's own dials rather than whatever the saved state's own process ran with.
      #
      # @param state [Hash] as `#to_h` produced it; string or symbol keys both accepted, since a
      #   round trip through JSON turns every key into a string
      # @param splice_probability [Float] see `#initialize`
      # @param favor_count [Integer] see `#initialize`
      # @param corpus_limit [Integer] see `#initialize`
      # @param max_prefix_depth [Integer] see `#initialize`
      # @return [Fuzzing::CoverageCampaign]
      def self.load(state, splice_probability:, favor_count:, corpus_limit: 64, max_prefix_depth: 6)
        new(splice_probability: splice_probability, favor_count: favor_count,
            corpus_limit: corpus_limit, max_prefix_depth: max_prefix_depth).tap { |campaign| campaign.restore!(state) }
      end

      private

      def tally(plan, trace)
        @seeds   += 1
        @spliced += 1 if plan.spliced?
        @declared_verbs.merge(trace.verbs)
      end

      # The step indexes whose tuples nothing had reached before; each tuple's verb counts as a hit.
      def new_tuple_steps(trace)
        trace.coverage.filter_map do |index, tuple|
          @verb_hits[tuple.split(" | ").first] += 1
          index if @seen.add?(tuple)
        end
      end

      def new_runtime?(runtime)
        runtime.to_a.map { |key| @runtime_seen.add?(key) }.any?
      end

      def splice_prefix(random)
        entry = @corpus[random.rand(@corpus.size)]
        entry[:spec].merge("steps" => random.rand(1..entry[:attempts]))
      end

      def admit(seed, plan, attempts)
        return if depth(plan.prefix) + 1 > @max_prefix_depth

        spec = { "seed" => seed, "favor" => plan.favor }
        spec["prefix"] = plan.prefix if plan.prefix
        @corpus << { spec: spec, attempts: attempts }
        @corpus.shift while @corpus.size > @corpus_limit
      end

      def depth(prefix) = prefix.nil? ? 0 : 1 + depth(prefix["prefix"])

      # Ties break by name so a plan is a pure function of what was recorded.
      def rare_verbs
        return [] unless @favor_count.positive?

        (@declared_verbs | @verb_hits.keys).min_by(@favor_count) { |verb| [@verb_hits[verb], verb] }
      end
    end
  end
end
