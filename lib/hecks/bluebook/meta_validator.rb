require "digest"
require "json"
require_relative "meta_validator/verdict_cache"

module Hecks
  module Bluebook
    # Judges a bluebook by dispatching it into the language declared in itself.
    # Refusals become `DSL::Malformed`; the meta-domain does the judging, not a builder.
    module MetaValidator
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

      # Whether the language's own grammar is still loading raw, unjudged.
      # Judging it while it loads would recurse, so the bootstrap sets this
      # and the fixpoint clears it once every grammar file is merged.
      #
      # @return [Boolean]
      def self.bootstrapping? = @bootstrapping

      # Whether `call` is queuing chapters instead of judging them, while a
      # chapter's own files are still being merged (see `defer`).
      #
      # @return [Boolean]
      def self.deferring? = @deferring

      # Queues every chapter `call` sees while the block runs, instead of
      # judging them immediately (see `deferred_chapters`).
      #
      # @yield the caller's own load of every file in one chapter window
      # @return [Object] the block's own return value
      def self.defer
        previous   = @deferring
        @deferring = true
        yield
      ensure
        @deferring = previous
      end

      # The chapters queued while `defer`'s block ran, awaiting
      # `judge_deferred!`.
      #
      # @return [Array<String>] each deferred chapter's own `hecks_name`,
      #   queued during the current or most recent `defer` window
      def self.deferred_chapters = @deferred_chapters ||= []

      # Judges every chapter queued by `defer`, once each, then clears the
      # queue.
      #
      # @param registry [Runtime::Registry, nil] the registry to judge
      #   against; a no-op if `nil`
      # @return [void]
      # @raise [DSL::Malformed] if a chapter's own whole-chapter battery
      #   (`BluebookBuilder.validate_assembled!`) or the meta-domain itself
      #   (`call`) refuses it
      def self.judge_deferred!(registry)
        pending = deferred_chapters.uniq
        @deferred_chapters = []
        return unless registry

        pending.each do |name|
          chapter = registry.bluebook(name)
          next unless chapter

          # Bare chapter-level givens must resolve before anything below
          # reads a `Given`'s fields. The `raise` block never runs — this
          # chapter's builder is always already open by the time `chapter` exists.
          builder = registry.bluebook_builder(name) { raise "internal: no open builder for #{name}" }
          builder.resolve_pending_chapter_givens!
          # Same, one level down: entity-scoped pending givens.
          builder.resolve_pending_chapter_entity_givens!

          # Whole-chapter checks (hops, projected fields, event shapes) were
          # skipped per file while deferring; `chapter` now holds every
          # file's declarations, so they run once here instead of per file.
          DSL::BluebookBuilder.validate_assembled!(chapter)
          registry.add_bluebook(call(chapter))
        end
      end

      # Whether meta-domain judging is off (ignored while a fixpoint build
      # is forced).
      # Stack-restored, not a bare flag, so a disabled window can never
      # leak past its own scope.
      #
      # @return [Boolean]
      def self.disabled? = @disabled && !@forcing_fixpoint

      # Runs `block` with `disabled?` true, restoring it afterward — for a
      # growth spec that boots a scratch bluebook without validation overhead.
      #
      # @yield the caller's own boot, with `disabled?` true throughout
      # @return [Object] the block's own return value
      def self.while_disabled
        previous  = @disabled
        @disabled = true
        yield
      ensure
        @disabled = previous
      end

      # (ADR 0025) Whether frozen era text is currently being shadow-parsed
      # by `EraGuard`. Judging it again here would refuse history whenever a
      # spelling it used gets removed from the live grammar.
      #
      # @return [Boolean]
      def self.shadow_parsing? = @shadow_parsing

      # Wraps `block` with `shadow_parsing?` true, restoring it afterward.
      #
      # @yield the caller's own shadow-parse of one piece of frozen era text
      # @return [Object] the block's own return value
      def self.while_shadow_parsing
        previous        = @shadow_parsing
        @shadow_parsing = true
        yield
      ensure
        @shadow_parsing = previous
      end

      # Wraps `block` with `disabled?` forced false, restoring it afterward.
      # Only `grammar_registry`'s one-time fixpoint build uses this.
      #
      # @yield the one-time fixpoint build, with `disabled?` forced false
      #   throughout
      # @return [Object] the block's own return value
      def self.while_forcing_fixpoint
        previous          = @forcing_fixpoint
        @forcing_fixpoint = true
        yield
      ensure
        @forcing_fixpoint = previous
      end

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
        return world if disabled? || bootstrapping? || shadow_parsing?

        key = Digest::SHA256.hexdigest(JSON.generate([world.domain, world.realm, world.latest, world.settings]))
        refusals = verdicts[key] ||= WorldJudge.new(world).refusals
        return world if refusals.empty?

        raise DSL::Malformed,
              "#{world.domain}'s world is not well formed; #{refusals.join('; ')}"
      end

      # Judges `port` through the meta-domain's own `PortJudge` door.
      #
      # @param port [Bluebook::Port] the port to judge
      # @return [Bluebook::Port] `port` unchanged, if well formed or while
      #   disabled/bootstrapping/shadow-parsing
      # @raise [DSL::Malformed] if `PortJudge` finds `port` malformed
      def self.call_port(port)
        return port if disabled? || bootstrapping? || shadow_parsing?

        key = Digest::SHA256.hexdigest(JSON.generate([port.name, port.verb, port.signal]))
        refusals = verdicts[key] ||= PortJudge.new(port).refusals
        return port if refusals.empty?

        raise DSL::Malformed,
              "#{port.name}'s port is not well formed; #{refusals.join('; ')}"
      end

      # Judges `adapter` through the meta-domain's own `AdapterJudge` door.
      #
      # @param adapter [Bluebook::Adapter] the adapter to judge
      # @return [Bluebook::Adapter] `adapter` unchanged, if well formed or
      #   while disabled/bootstrapping/shadow-parsing
      # @raise [DSL::Malformed] if `AdapterJudge` finds `adapter` malformed
      def self.call_adapter(adapter)
        return adapter if disabled? || bootstrapping? || shadow_parsing?

        key = Digest::SHA256.hexdigest(JSON.generate([adapter.name, adapter.port, adapter.fields, adapter.secrets]))
        refusals = verdicts[key] ||= AdapterJudge.new(adapter).refusals
        return adapter if refusals.empty?

        raise DSL::Malformed,
              "#{adapter.name}'s adapter is not well formed; #{refusals.join('; ')}"
      end

      # Judges `translation` through the meta-domain's own `TranslationJudge`
      # door, walking every nested aggregate's own rule table in one pass.
      #
      # @param translation [Bluebook::Translation] the translation to judge
      # @return [Bluebook::Translation] `translation` unchanged, if well
      #   formed or while disabled/bootstrapping/shadow-parsing
      # @raise [DSL::Malformed] if `TranslationJudge` finds `translation`
      #   malformed
      def self.call_translation(translation)
        return translation if disabled? || bootstrapping? || shadow_parsing?

        # `Translation` has no `.to_h`; `.inspect` embeds an object-id, so
        # structurally-identical translations never cache-hit here (a lost
        # optimization, not a correctness issue).
        key = Digest::SHA256.hexdigest(translation.inspect)
        refusals = verdicts[key] ||= TranslationJudge.new(translation).refusals
        return translation if refusals.empty?

        raise DSL::Malformed,
              "#{translation.domain}'s translation is not well formed; #{refusals.join('; ')}"
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

        if deferring?
          deferred_chapters << bluebook.hecks_name
          return bluebook
        end

        key = Digest::SHA256.hexdigest(JSON.generate(bluebook.to_h))
        held = verdicts[key] || (verdicts[key] = hold(bluebook).tap { |fresh| VerdictCache.record(key, fresh) })

        unless held[:refusals].empty?
          raise DSL::Malformed,
                "#{bluebook.hecks_name} is not a well-formed bluebook; #{held[:refusals].join('; ')}"
        end

        Assembly.call(held[:declaration])
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
      # judged against — built once per process and memoized.
      #
      # @return [Runtime::Registry] the booted, fixpoint-judged language
      #   registry
      def self.grammar_registry
        @grammar_registry ||= begin
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
        Hecks.with_registry(registry) do
          Kernel.load(File.expand_path("../ports/persistence.port", __dir__))
          Kernel.load(File.expand_path("../ports/extraction.port", __dir__))
          Kernel.load(File.expand_path("../adapters/driven/memory.adapter", __dir__))
          Kernel.load(File.expand_path("../adapters/driven/prism.adapter", __dir__))
          GRAMMAR_FILES.each { |file| Kernel.load(file) }
          WORLD_GRAMMAR.each { |file| Kernel.load(file) }
          HECKSAGON_GRAMMAR.each { |file| Kernel.load(file) }
          Kernel.load(PORT_GRAMMAR)
          Kernel.load(ADAPTER_GRAMMAR)
          TRANSLATION_GRAMMAR.each { |file| Kernel.load(file) }
        end
        registry
      ensure
        @bootstrapping = false
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
