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

      def self.call(bluebook)
        return bluebook if disabled? || bootstrapping?

        key = Digest::SHA256.hexdigest(JSON.generate(bluebook.to_h))
        refusals = verdicts[key] ||= Judge.new(bluebook).refusals
        return bluebook if refusals.empty?

        raise DSL::Malformed,
              "#{bluebook.name} is not a well-formed bluebook; #{refusals.join('; ')}"
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
