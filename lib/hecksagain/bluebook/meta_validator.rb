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

      # The meta-domain is itself a bluebook. Judging it while loading it would
      # recurse, so the load path marks the bootstrap and skips.
      def self.bootstrapping? = @bootstrapping

      def self.disabled? = ENV["HECKSAGAIN_META_VALIDATION"] == "off"

      # The same bluebook judged twice gets the same verdict, and a suite reloads
      # its fixtures constantly — banking alone is ~200 dispatches per build.
      # Keyed on the IR itself, so a CHANGED bluebook is always re-judged.
      def self.verdicts = @verdicts ||= {}

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
          end
          registry
        ensure
          @bootstrapping = false
        end
      end

      # Walks one built bluebook and offers every declaration to the meta-domain.
      # Only the DISPATCH half of the round trip lives here — reconstruction is
      # the experiment's business, and validation does not need it.
      class Judge
        attr_reader :refusals

        def initialize(bluebook)
          @bluebook = bluebook
          @refusals = []
          @runtime  = fresh_runtime
          judge!
        end

        private

        # A FRESH STORE per bluebook. The registry memoises repositories, so
        # reusing it let every bluebook see the records of every bluebook judged
        # before it — one domain's declarations shadowing another's, and the
        # store growing for the life of the process. The parsed grammar is
        # reused (it is expensive) ; only the records are cleared.
        def fresh_runtime
          registry = MetaValidator.grammar_registry
          registry.instance_variable_set(:@repositories, {})
          Runtime::Loader.bind_runtime(Runtime::Dispatcher.new(registry))
        end

        # ABSENT is not EMPTY. The builders' rules read "if you declare it,
        # declare something" — a description never given is legal. Passing ""
        # for nil turned every one of them into "you must declare it", which
        # refused 73 existing examples. Omitted args stay omitted.
        def v(text) = text.nil? ? nil : { value: text.to_s }

        def args(pairs) = pairs.reject { |_, value| value.nil? }

        def offer(label)
          yield
        rescue Runtime::GivenNotMet, Runtime::InvariantViolation, Runtime::TypeMismatch => e
          @refusals << "#{label}: #{e.message}"
        rescue Runtime::NotFound, Runtime::UnknownVerb
          # a declaration the meta-domain has no shape for yet is not a defect
          # in the bluebook being judged
          nil
        end

        def judge!
          chapter = @bluebook.name
          offer("#{chapter}") do
            @runtime.dispatch("Meta::Chapter.Declare", **args(name: v(chapter),
                              vision: v(@bluebook.vision), classification: v(@bluebook.classification)))
          end
          @bluebook.aggregates.each { |aggregate| judge_aggregate(chapter, aggregate) }
        end

        def judge_aggregate(chapter, aggregate)
          root = "#{chapter}::#{aggregate.name}"
          offer(root) do
            @runtime.dispatch("Meta::Root.Declare", **args(id: root, chapter_id: v(chapter),
                              name: v(aggregate.name), description: v(aggregate.description),
                              identity: v(aggregate.identified_by)))
          end

          aggregate.attributes.each do |attribute|
            offer("#{root}##{attribute.name}") do
              @runtime.dispatch("Meta::Root.Attribute", **args(id: root, name: v(attribute.name),
                                type: v(attribute.type), list: v(attribute.list?)))
            end
          end

          aggregate.value_objects.each { |shape| judge_shape(root, aggregate, shape) }
          aggregate.commands.each { |command| judge_command(root, aggregate, command) }
        end

        def judge_shape(root, aggregate, shape)
          id = "#{root}.#{shape.name}"
          offer(id) do
            @runtime.dispatch("Meta::Shape.Declare", **args(id: id, root_id: v(aggregate.name), name: v(shape.name)))
          end
          shape.invariants.each do |invariant|
            offer(id) do
              @runtime.dispatch("Meta::Shape.Assert", **args(id: id,
                                description: v(invariant.description), canonical: v(invariant.canonical)))
            end
          end
        end

        def judge_command(root, aggregate, command)
          id = "#{root}.#{command.name}"
          offer(id) do
            @runtime.dispatch("Meta::Verb.Declare", **args(id: id, root_id: v(aggregate.name),
                              name: v(command.name), role: v(command.role), goal: v(command.goal)))
          end

          command.givens.each do |given|
            offer(id) do
              @runtime.dispatch("Meta::Verb.Rule", **args(id: id,
                                description: v(given.description), canonical: v(given.canonical)))
            end
          end

          command.mutations.each do |mutation|
            offer("#{id}!#{mutation.target}") do
              @runtime.dispatch("Meta::Verb.Change", **args(id: id, target: v(mutation.target),
                                op: v(mutation.op), field: v(""), kind: v("argument"), source: v("")))
            end
          end

          Array(command.emits).each do |event|
            offer(id) { @runtime.dispatch("Meta::Verb.Announce", **args(id: id, announces: v(event))) }
          end
        end
      end
    end
  end
end
