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
        @verb_hits          = Hash.new(0)
        @declared_verbs     = Set.new
        @seeds              = 0
        @spliced            = 0
        @seeds_with_new     = 0
      end

      # Builds this seed's plan: a possible corpus splice, plus the verbs to favor.
      #
      # @param seed [Integer] drives the splice coin flip, the corpus entry and the prefix length
      # @return [Fuzzing::CoverageCampaign::Plan]
      def plan(seed)
        random = Random.new(seed)
        prefix = nil
        if !@corpus.empty? && random.rand < @splice_probability
          entry  = @corpus[random.rand(@corpus.size)]
          prefix = entry[:spec].merge("steps" => random.rand(1..entry[:attempts]))
        end
        Plan.new(prefix: prefix, favor: rare_verbs)
      end

      # Folds one seed's trace into the running coverage; admits a corpus entry if it reached
      # a new tuple.
      #
      # @param seed [Integer] the seed the trace was generated from
      # @param plan [Fuzzing::CoverageCampaign::Plan] the plan that seed ran with
      # @param trace [Fuzzing::SequenceGenerator::Trace] from `SequenceGenerator.trace`
      # @return [void]
      def record(seed, plan, trace)
        @seeds   += 1
        @spliced += 1 if plan.spliced?
        @declared_verbs.merge(trace.verbs)

        new_at = trace.coverage.filter_map do |index, tuple|
          @verb_hits[tuple.split(" | ").first] += 1
          index if @seen.add?(tuple)
        end
        return if new_at.empty?

        @seeds_with_new += 1
        admit(seed, plan, new_at.max + 1)
      end

      # The number of distinct coverage tuples reached so far.
      def tuples_seen = @seen.size

      # One line of running totals: tuples seen, seeds run, seeds with new coverage, splices.
      def summary
        "coverage: #{@seen.size} distinct (verb, kind, state, mutation, outcome) tuple(s) over #{@seeds} seed(s); " \
          "#{@seeds_with_new} seed(s) reached something new; #{@spliced} spliced from a corpus of #{@corpus.size}"
      end

      private

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
