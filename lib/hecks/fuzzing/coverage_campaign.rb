module Hecks
  module Fuzzing
    # What one sweep has already reached, and where the next seed starts.
    #
    # `SequenceGenerator` steers within one sequence (an unexercised verb is
    # weighted up — picker.rb's `steer`), but without this, every seed of a
    # sweep would start from nothing and forget everything the seeds before
    # it reached. Roughly half of the QA ledger's bugs are refusal-kind splits (BUG#2–4,
    # 7, 8, 14–16, 19–21, 23, 27, 28, 36–38, 41, 54, 56): a particular verb,
    # in a particular state, with a particular malformed argument, refused
    # one way on Ruby and another on Rust. BUG#11 was found by hand because
    # a 25-step random walk never reached `Annotate` at all. Uniform seeds
    # reach those corners by luck; this makes the sweep remember.
    #
    # ## The coverage unit
    #
    # A tuple, not a verb — `verb | step kind | lifecycle state before |
    # adversarial mutation | outcome` (see `SequenceGenerator#coverage_tuple`).
    # "Renew refused LifecycleRefused from free" and "Renew ok from held" are
    # different places a runtime can be wrong, where a verb-level count
    # calls them the same.
    #
    # ## Two levers
    #
    # Both expressed as plain generator arguments so a seed stays
    # reproducible from one call:
    #
    #   1. Splicing (`prefix:`). A sequence that reached a new tuple joins
    #      the corpus, cut at its last new tuple. A later seed may start by
    #      re-generating a random-length prefix of a corpus entry — the same
    #      seed, favor and nested prefix, so the same steps, dispatched for
    #      real, reaching the same state — and then carries on with its own
    #      seed's randomness from there. Deep state gets reached once and
    #      explored many times, instead of re-rolled per seed.
    #   2. Favor (`favor:`). The verbs this sweep has hit least often —
    #      including declared verbs it has never hit at all — are weighted
    #      up for the next seed.
    #
    # ## Reproducibility
    #
    # Nothing here is random at the campaign's own level beyond
    # `Random.new(seed)` per plan, and a plan is printed with every finding
    # (`bin/qa_sweep`'s `reproduce:` line), so no finding depends on
    # re-running the whole campaign to get back to it.
    class CoverageCampaign
      # One seed's generation instructions, printable and reproducible.
      Plan = Struct.new(:prefix, :favor, keyword_init: true) do
        # Renders this plan as the keyword arguments a generator call accepts.
        #
        # @return [Hash{Symbol => Object}] `{ prefix:, favor: }`, the keyword arguments
        #   `SequenceGenerator.generate` and `.trace` accept for this plan
        def generator_options = { prefix: prefix, favor: favor }

        # Answers whether this plan starts from a spliced corpus prefix.
        #
        # @return [Boolean] whether this plan starts from a spliced corpus prefix
        def spliced? = !prefix.nil?
      end

      attr_reader :corpus

      # @param splice_probability [Float, Integer] chance, per seed with a non-empty
      #   corpus, of splicing a corpus entry's prefix instead of generating fresh
      # @param favor_count [Integer, Float] how many rare verbs to favor per plan; 0
      #   or non-positive disables favoring entirely
      # @param corpus_limit [Integer] maximum corpus entries kept; the oldest is
      #   dropped once this is exceeded
      # @param max_prefix_depth [Integer] maximum nested-prefix depth a new corpus
      #   entry may reach before splicing stops extending it further
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

      # Builds this seed's generation plan — a possible splice, plus which
      # verbs to favor.
      #
      # @param seed [Integer] the seed this plan is for; drives the splice-or-not
      #   coin flip and, when splicing, which corpus entry and prefix length are drawn
      # @return [Fuzzing::CoverageCampaign::Plan] the plan `SequenceGenerator.generate`
      #   or `.trace` should be run with for this seed
      def plan(seed)
        random = Random.new(seed)
        prefix = nil
        if !@corpus.empty? && random.rand < @splice_probability
          entry  = @corpus[random.rand(@corpus.size)]
          prefix = entry[:spec].merge("steps" => random.rand(1..entry[:attempts]))
        end
        Plan.new(prefix: prefix, favor: rare_verbs)
      end

      # Folds one seed's generation results into the campaign's running
      # coverage, and admits its corpus entry if it reached anything new.
      #
      # @param seed [Integer] the seed this trace was generated from
      # @param plan [Fuzzing::CoverageCampaign::Plan] the plan that seed was generated with
      # @param trace [Fuzzing::SequenceGenerator::Trace] `SequenceGenerator.trace`'s answer:
      #   `coverage` is `[[attempt_index, tuple], ...]`, `verbs` every verb the booted
      #   catalog offered
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

      # Counts the distinct coverage tuples this campaign has reached so far.
      #
      # @return [Integer] the number of distinct coverage tuples seen
      def tuples_seen = @seen.size

      # Renders the campaign's running totals as one human-readable line.
      #
      # @return [String] a one-line summary of tuples seen, seeds run, seeds that
      #   reached something new, and how many were spliced from the corpus
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

      # Never-hit declared verbs first (hits 0), then the least-hit, ties
      # broken by name so a plan is a pure function of what was recorded.
      def rare_verbs
        return [] unless @favor_count.positive?

        (@declared_verbs | @verb_hits.keys).min_by(@favor_count) { |verb| [@verb_hits[verb], verb] }
      end
    end
  end
end
