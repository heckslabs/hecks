require "digest"
require "json"

module Hecksagain
  module Bluebook
    # Judges a bluebook by DISPATCHING it into the language declared in itself.
    #
    # `lib/hecksagain/grammar/bluebook.bluebook` declares what a bluebook IS —
    # Chapter, Root, Verb, Shape, Ask, Piece, and the rest — and carries the
    # language's rules as `given` and `invariant` rather than as `raise
    # Malformed` scattered across seven builder files. This replays a built IR
    # into that domain and turns any refusal into a Malformed, so the meta-domain
    # is what actually judges rather than a description sitting beside the code.
    #
    # Delete grammar/bluebook.bluebook and validation stops. That is the whole
    # point : a self-description that only describes is indistinguishable from
    # enforcement, and the first version of this file was deleted for exactly
    # that reason.
    #
    # The meta-domain is loaded ONCE and its registry reused ; each bluebook is
    # judged in a fresh in-memory store so no domain can see another's records.
    module MetaValidator
      GRAMMAR = File.expand_path("../language/bluebook.bluebook", __dir__).freeze
      # a world is a SIBLING artifact, described in its own file
      WORLD_GRAMMAR = File.expand_path("../language/world.bluebook", __dir__).freeze

      # The meta-domain is itself a bluebook. Judging it while loading it would
      # recurse, so the load path marks the bootstrap and skips.
      def self.bootstrapping? = @bootstrapping

      def self.disabled? = ENV["HECKSAGAIN_META_VALIDATION"] == "off"

      # The same bluebook judged twice gets the same verdict, and a suite reloads
      # its fixtures constantly — banking alone is ~200 dispatches per build.
      # Keyed on the IR itself, so a CHANGED bluebook is always re-judged.
      def self.verdicts = @verdicts ||= {}

      # A world is not a bluebook, so it gets its own door. Same judge, same
      # meta-domain registry — a different artifact and a different language file.
      def self.call_world(world)
        return world if disabled? || bootstrapping?

        key = Digest::SHA256.hexdigest(JSON.generate([world.domain, world.realm, world.latest, world.settings]))
        refusals = verdicts[key] ||= WorldJudge.new(world).refusals
        return world if refusals.empty?

        raise DSL::Malformed,
              "#{world.domain}'s world is not well formed; #{refusals.join('; ')}"
      end

      # THE LANGUAGE HANDS THE GRAPH BACK.
      #
      # This used to return the bluebook it was given — dispatch every declaration
      # in, collect refusals, throw the records away — which is all JUDGING needs
      # and exactly why the language could only validate. It returns what the
      # meta-domain HOLDS instead, assembled into the graph the runtime runs. The
      # builder's own object graph now exists only to be dispatched; nothing keeps
      # it.
      #
      # `Hecks.bluebook` registers whatever comes back from here, so this one line
      # is the difference between a language that checks a domain and a language
      # that is the source of one.
      #
      # What is CACHED is the declarations, not the graph. A hash carries no Ruby
      # classes, so a second load of the same chapter re-assembles fresh ones —
      # which is the behaviour `Namespace.install` and `spec/construct_spec` both
      # expect. Caching the graph would hand two boots the same classes.
      # NOT YET THE SOURCE, and the reason is an exact list.
      #
      # Returning `Assembly.call(held[:declaration])` here is the whole swap — the
      # runtime would run what the language HOLDS instead of what the builder made,
      # because `Hecks.bluebook` registers whatever comes back from this method. It
      # was tried, and it works for everything the language can hold: the corpus
      # runs, both runtimes agree, the wire format does not move.
      #
      # Three things stop it, all of them holes in the IR rather than in the
      # language, and `spec/orchestration_spec` names each one as an exact
      # difference so the distance is measured instead of guessed:
      #
      #   1. `ReadModel#to_h` omits wheres, order_by and limit entirely — and so
      #      does Rust's ReadModel struct, which has five fields and none of them
      #      are filters. A read model's filtering has never been part of the
      #      cross-language contract, so it cannot be read back. Closing it is a
      #      feature in TWO runtimes, not a refactor.
      #   2. `Aggregate#to_h` omits policies. The builder hoists a policy declared
      #      inside a head onto the chapter, so the language holds the policy but
      #      not which head wrote it.
      #   3. `Query.Option` and `ReadModel.Option` are declared and unexercised —
      #      no corpus query carries an offset or a freshness, so the judge never
      #      offers those verbs and `spec/judge_coverage_spec` calls them
      #      decoration. Exercising them means teaching Rust the same options.
      #
      # Everything else is in place: the reconstruction reads in declaration order,
      # `Assembly` rebuilds the graph from one table held to the language, and the
      # equivalence is pinned. What is left is a wire-format decision, and it is
      # Chris's rather than mine.
      def self.call(bluebook)
        return bluebook if disabled? || bootstrapping?

        key = Digest::SHA256.hexdigest(JSON.generate(bluebook.to_h))
        held = verdicts[key] ||= hold(bluebook)
        return bluebook if held[:refusals].empty?

        raise DSL::Malformed,
              "#{bluebook.hecks_name} is not a well-formed bluebook; #{held[:refusals].join('; ')}"
      end

      # Dispatch it in and READ IT BACK. A refused chapter has no declarations to
      # read — the records are half-written by definition — so it carries refusals
      # and nothing else.
      def self.hold(bluebook)
        judge = Judge.new(bluebook)
        return { refusals: judge.refusals } unless judge.refusals.empty?

        { refusals: [], declaration: Reconstruction.of(judge.runtime, bluebook.hecks_name) }
      end

      def self.grammar_registry
        @grammar_registry ||= begin
          @bootstrapping = true
          registry = Runtime::Registry.new
          Hecksagain.with_registry(registry) do
            Kernel.load(File.expand_path("../ports/persistence/persistence.port", __dir__))
            Kernel.load(File.expand_path("../ports/extraction/extraction.port", __dir__))
            Kernel.load(File.expand_path("../adapters/driven/memory/memory.adapter", __dir__))
            Kernel.load(File.expand_path("../adapters/driven/prism/prism.adapter", __dir__))
            Kernel.load(GRAMMAR)
            Kernel.load(WORLD_GRAMMAR)
          end
          registry
        ensure
          @bootstrapping = false
        end
      end

      # A FRESH STORE per bluebook. The registry memoises repositories, so
      # reusing it let every bluebook see the records of every bluebook judged
      # before it. The parsed grammar is reused ; only the records are cleared.
      def self.fresh_runtime
        registry = grammar_registry
        registry.instance_variable_set(:@repositories, {})
        Runtime::Loader.bind_runtime(Runtime::Dispatcher.new(registry))
      end
    end
  end
end
