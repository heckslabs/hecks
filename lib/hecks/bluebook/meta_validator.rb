require "digest"
require "json"
require_relative "meta_validator/verdict_cache"
require_relative "meta_validator/modes"

module Hecks
  module Bluebook
    # Judges a bluebook by dispatching it into the language declared in itself.
    # Refusals become `DSL::Malformed`; the meta-domain does the judging, not a builder.
    module MetaValidator
      extend Modes

      # Deterministic file order becomes the source order exported to IR.
      GRAMMAR_DIR   = File.expand_path("../language/bluebook", __dir__).freeze
      GRAMMAR_FILES = Dir.glob(File.join(GRAMMAR_DIR, "*.bluebook")).freeze
      WORLD_GRAMMAR = Dir.glob(File.expand_path("../language/world/*.bluebook", __dir__)).freeze
      HECKSAGON_GRAMMAR = Dir.glob(File.expand_path("../language/hecksagon/*.bluebook", __dir__)).freeze
      # Backs PortJudge, the same door shape as WorldJudge.
      PORT_GRAMMAR = File.expand_path("../language/port.bluebook", __dir__).freeze
      # Backs AdapterJudge, one file over.
      ADAPTER_GRAMMAR = File.expand_path("../language/adapter.bluebook", __dir__).freeze
      # Backs TranslationJudge, one file over.
      TRANSLATION_GRAMMAR = Dir.glob(File.expand_path("../language/translation/*.bluebook", __dir__)).freeze

      # (ADR 0026) Any bluebook file placed here is auto-discovered and
      # loaded as an extension chapter; nothing else in this file changes.
      ATTACHED_GRAMMAR_DIR = File.expand_path("../language/bluebook/attaches", __dir__).freeze

      # The chapters loaded raw at bootstrap, then judged through themselves
      # and replaced by their own self-assembled graphs.
      LANGUAGE_CHAPTERS = %w[Bluebook World Hecksagon].freeze

      # Process-wide judging cache, keyed on a SHA-256 digest of the judged
      # artifact so a changed bluebook is always re-judged.
      #
      # Seeded once per process with the chapter verdicts earlier processes
      # stored (see `VerdictCache`); every other verdict starts empty.
      #
      # @return [Hash{String => Object}] refusal messages per digest for a
      #   world/port/adapter/translation (`[]` when well formed); the held
      #   verdict Hash for a chapter
      def self.verdicts = @verdicts ||= VerdictCache.seed

      # Judges `world` through the meta-domain's own `WorldJudge` door.
      #
      # @param world [Bluebook::World] the world to judge
      # @return [Bluebook::World] `world` unchanged, if well formed or
      #   while disabled/bootstrapping/shadow-parsing
      # @raise [DSL::Malformed] if `WorldJudge` finds `world` malformed
      def self.call_world(world)
        judge_door(world, WorldJudge, "#{world.domain}'s world") do
          JSON.generate([world.domain, world.realm, world.latest, world.settings])
        end
      end

      # Judges `port` through the meta-domain's own `PortJudge` door.
      #
      # @param port [Bluebook::Port] the port to judge
      # @return [Bluebook::Port] `port` unchanged, if well formed or while
      #   disabled/bootstrapping/shadow-parsing
      # @raise [DSL::Malformed] if `PortJudge` finds `port` malformed
      def self.call_port(port)
        judge_door(port, PortJudge, "#{port.name}'s port") { JSON.generate([port.name, port.verb, port.signal]) }
      end

      # Judges `adapter` through the meta-domain's own `AdapterJudge` door.
      #
      # @param adapter [Bluebook::Adapter] the adapter to judge
      # @return [Bluebook::Adapter] `adapter` unchanged, if well formed or
      #   while disabled/bootstrapping/shadow-parsing
      # @raise [DSL::Malformed] if `AdapterJudge` finds `adapter` malformed
      def self.call_adapter(adapter)
        judge_door(adapter, AdapterJudge, "#{adapter.name}'s adapter") do
          JSON.generate([adapter.name, adapter.port, adapter.fields, adapter.secrets])
        end
      end

      # Judges `translation` through the meta-domain's own `TranslationJudge`
      # door, walking every nested aggregate's own rule table in one pass.
      #
      # `Translation` has no `.to_h`; `.inspect` embeds an object-id, so
      # structurally-identical translations never cache-hit here (a lost
      # optimization, not a correctness issue).
      #
      # @param translation [Bluebook::Translation] the translation to judge
      # @return [Bluebook::Translation] `translation` unchanged, if well
      #   formed or while disabled/bootstrapping/shadow-parsing
      # @raise [DSL::Malformed] if `TranslationJudge` finds `translation`
      #   malformed
      def self.call_translation(translation)
        judge_door(translation, TranslationJudge, "#{translation.domain}'s translation") { translation.inspect }
      end

      # The one door every artifact but a chapter goes through: skip while judging is off,
      # else judge once per distinct `key_text` and refuse a malformed artifact.
      #
      # @param subject [Object] the artifact to judge
      # @param judge [Class] the judge to build over `subject`; it answers `refusals`
      # @param label [String] how the refusal names `subject`
      # @yieldreturn [String] the text whose SHA-256 digest keys the verdict
      # @return [Object] `subject` unchanged, if well formed or while judging is off
      # @raise [DSL::Malformed] if `judge` finds `subject` malformed
      def self.judge_door(subject, judge, label)
        return subject if disabled? || bootstrapping? || shadow_parsing?

        key = Digest::SHA256.hexdigest(yield)
        refusals = verdicts[key] ||= judge.new(subject).refusals
        return subject if refusals.empty?

        raise DSL::Malformed, "#{label} is not well formed; #{refusals.join("; ")}"
      end

      # Dispatches `bluebook` into the language and returns the graph the
      # meta-domain assembles from its own judged declarations, not the
      # builder's original object graph.
      #
      # @param bluebook [Object] a built bluebook chapter graph (an
      #   `Aggregate`/`Entity`/`ValueObject`/... instance from
      #   `lib/hecks/bluebook/`), answering `to_h` and `hecks_name`
      # @return [Object] `bluebook` unchanged while disabled, bootstrapping,
      #   shadow-parsing, or deferring; otherwise the graph the meta-domain
      #   assembles from its own judged declarations
      # @raise [DSL::Malformed] if the meta-domain refuses any of
      #   `bluebook`'s declarations
      def self.call(bluebook)
        return bluebook if disabled? || bootstrapping? || shadow_parsing?

        return defer_chapter(bluebook) if deferring?

        held = held_verdict(bluebook)
        unless held[:refusals].empty?
          raise DSL::Malformed,
                "#{bluebook.hecks_name} is not a well-formed bluebook; #{held[:refusals].join("; ")}"
        end

        Assembly.call(held[:declaration])
      end

      # @param bluebook [Object] a built bluebook chapter graph
      # @return [Object] `bluebook`, queued for `judge_deferred!`
      def self.defer_chapter(bluebook)
        deferred_chapters << bluebook.hecks_name
        bluebook
      end

      # @param bluebook [Object] a built bluebook chapter graph
      # @return [Hash{Symbol => Object}] the verdict `hold` produced for it, cached by digest
      def self.held_verdict(bluebook)
        key = Digest::SHA256.hexdigest(JSON.generate(bluebook.to_h))
        verdicts[key] || (verdicts[key] = hold(bluebook).tap { |fresh| VerdictCache.record(key, fresh) })
      end

      # Dispatches `bluebook` into the meta-domain and reads the result back.
      # A refused chapter carries only its refusals — the records are
      # half-written by definition.
      #
      # @param bluebook [Object] a built bluebook chapter graph, as `call`
      #   receives it
      # @return [Hash{Symbol => Object}] `{refusals: [...]}` when `Judge`
      #   refuses any declaration; otherwise `{refusals: [],
      #   declaration: Hash}`, the assembled graph `Reconstruction.of` reads
      #   back from the judged records
      def self.hold(bluebook)
        judge = Judge.new(bluebook)
        return { refusals: judge.refusals } unless judge.refusals.empty?

        { refusals: [], declaration: Reconstruction.of(judge.runtime, bluebook.hecks_name) }
      end

      # The booted, self-judged language registry every ordinary bluebook is
      # judged against — built once per process and memoized, with shadow parsing off: a caller
      # inside `while_shadow_parsing` that is first to ask would otherwise memoize a grammar
      # parsed in that mode, or fail to load it.
      #
      # @return [Runtime::Registry] the booted, fixpoint-judged language
      #   registry
      def self.grammar_registry
        @grammar_registry ||= while_not_shadow_parsing do
          registry = load_grammar_into(Runtime::Registry.new)
          # Assigned before the fixpoint judge below, since judging re-enters
          # grammar_registry (via fresh_runtime/Plan.for) and a bare `||=`
          # would still be nil mid-evaluation, recursing forever.
          @grammar_registry = registry
          # The language now judges itself; every bluebook from here on is
          # judged by that assembled graph, not the raw bootstrap one. Must
          # run after load_grammar_into's ensure clears @bootstrapping.
          while_forcing_fixpoint do
            LANGUAGE_CHAPTERS.each { |name| registry.add_bluebook(call(registry.bluebook(name))) }
            load_attached_grammar_into(registry)
          end
          # Keyed on this registry's object identity, not a bare boolean, so
          # a manual reset can never leave a stale "ready" from the previous
          # cycle.
          @grammar_ready_for = registry.object_id
          registry
        end
      end

      # Whether `grammar_registry`'s memoized singleton has finished its
      # fixpoint judge and attached-chapter load.
      #
      # A cache keyed on "finished" instead of its own inputs already missed
      # data for a whole build window once.
      #
      # @return [Boolean]
      def self.grammar_registry_ready?
        @grammar_registry && @grammar_ready_for == @grammar_registry.object_id
      end

      # Loads every `ATTACHED_GRAMMAR_DIR` chapter file into `registry`,
      # judged the ordinary way since the fixpoint has already run.
      #
      # @param registry [Runtime::Registry] the registry to load every
      #   `ATTACHED_GRAMMAR_DIR` chapter file into
      # @return [void]
      def self.load_attached_grammar_into(registry)
        Hecks.with_registry(registry) do
          Dir.glob(File.join(ATTACHED_GRAMMAR_DIR, "*.bluebook")).each { |file| Kernel.load(file) }
        end
      end

      # Loads the whole grammar (ports, adapters, every language chapter)
      # into `registry`, raw and unjudged.
      #
      # The `@bootstrapping` guard matters: without it a chapter split
      # across files would get judged one file at a time and refuse early.
      #
      # @param registry [Runtime::Registry] the registry to load the whole
      #   grammar into, raw and unjudged
      # @return [Runtime::Registry] `registry`, unchanged in identity
      def self.load_grammar_into(registry)
        @bootstrapping = true
        Hecks.with_registry(registry) { grammar_files.each { |file| Kernel.load(file) } }
        registry
      ensure
        @bootstrapping = false
      end

      # @return [Array<String>] every file `load_grammar_into` loads, in load order
      def self.grammar_files
        preamble = ["../ports/persistence.port", "../ports/extraction.port",
                    "../adapters/driven/memory.adapter", "../adapters/driven/prism.adapter"]
        preamble.map { |path| File.expand_path(path, __dir__) } +
          GRAMMAR_FILES + WORLD_GRAMMAR + HECKSAGON_GRAMMAR + [PORT_GRAMMAR, ADAPTER_GRAMMAR] + TRANSLATION_GRAMMAR
      end

      # A dispatcher over the shared grammar registry with its records
      # cleared, so one bluebook's judging can never see another's records.
      #
      # @return [Runtime::Dispatcher] a dispatcher over the shared grammar
      #   registry, with its records cleared
      def self.fresh_runtime
        registry = grammar_registry
        registry.instance_variable_set(:@repositories, {})
        Runtime::Dispatcher.new(registry)
      end
    end
  end
end
