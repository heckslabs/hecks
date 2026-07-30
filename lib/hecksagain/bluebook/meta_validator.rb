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
      # THE LANGUAGE IS THE SOURCE. This is the line that makes it one.
      #
      # `Hecks.bluebook` registers whatever comes back from here, so returning the
      # assembled graph rather than the bluebook it was handed is the whole swap: the
      # runtime runs what the meta-domain HOLDS. The builder's own graph exists only
      # to be dispatched in ; nothing keeps it.
      #
      # It stayed unlanded for one wrong belief, worth naming because it looked so
      # much like a wall: that the language may only hold what `to_h` carries.
      # `ReadModel#to_h` omits a read model's filters and Rust's ReadModel struct has
      # no room for them, so read-model filtering seemed impossible to read back —
      # and hoisted policies lost which head declared them for the same reason.
      # But `to_h` is a PROJECTION for the other runtime and the language is the
      # SOURCE. They must agree about everything to_h spells ; they need not be the
      # same size. Both are held now, as declarations the wire format never sees, and
      # the wire format did not move an inch.
      #
      # What is CACHED is the declarations, not the graph. A hash carries no Ruby
      # classes, so a second load of the same chapter assembles fresh ones — which is
      # what `Namespace.install` and `spec/construct_spec` both expect. Caching the
      # graph would hand two boots the same classes.
      def self.call(bluebook)
        return bluebook if disabled? || bootstrapping?

        key = Digest::SHA256.hexdigest(JSON.generate(bluebook.to_h))
        held = verdicts[key] ||= hold(bluebook)

        unless held[:refusals].empty?
          raise DSL::Malformed,
                "#{bluebook.hecks_name} is not a well-formed bluebook; #{held[:refusals].join('; ')}"
        end

        Assembly.call(held[:declaration])
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
