require "digest"
require "json"

module Hecks
  module Bluebook
    # Judges a bluebook by dispatching it into the language declared in itself.
    #
    # `lib/hecks/language/bluebook/` declares what a bluebook is —
    # Chapter, Root, Verb, Shape, Ask, Piece, and the rest, split across files
    # by domain concept and merged into one chapter at load time (see
    # GRAMMAR_FILES below). This replays a built IR into that domain and turns
    # any refusal into a Malformed, so the meta-domain is what actually judges
    # rather than a description sitting beside the code — for whatever rules
    # it carries. `spec/meta_rules_spec.rb`'s own header names the plan: port
    # the language's rules out of builder `raise Malformed` calls and into
    # `given`/`invariant` here, where they are declarations any reader of the
    # meta-domain can consume instead of behavior buried in a builder.
    #
    # ## Migration status
    #
    # **This migration is partial, not done**. As of this writing the meta-domain
    # declares 62 given/invariant/ensures rules (`Hecks::QueryIR.collect_rules`
    # against `grammar_registry.bluebook("Bluebook")` enumerates them) —
    # `spec/meta_rule_reachability_spec.rb` is what proves, per declaration,
    # not per verb, that most of them still lack a spec exercising the
    # refusal at all (see that file's own KNOWN_GAPS for the current count).
    # Meanwhile `lib/hecks/bluebook/dsl/` still carries well over a hundred
    # `raise Malformed` calls of its own — some are genuinely pre-IR
    # construction errors (arity, argument shape) that cannot become
    # meta-domain rules, and some are exactly the semantic kind this file
    # claims to have moved (see `aggregate_builder.rb`'s `seal_*` passes:
    # a mutation into a field the aggregate never declares, a lifecycle guard
    # on an aggregate with no lifecycle). No doc currently inventories which
    # is which, or tracks migrating the latter — that inventory is the actual
    # next step, not a "delete the folder" thought experiment.
    #
    # ## What's actually enforced
    #
    # So: "delete language/bluebook/ and validation stops" is true for the 62
    # rules actually declared here, and false for whatever a builder's own
    # `raise Malformed` still checks — the language does not yet own its own
    # enforcement end to end. The self-hosting mechanism itself is real and
    # is the point worth keeping : a self-description that only describes is
    # indistinguishable from enforcement, and the first version of this file
    # was deleted for exactly that reason. What is not yet real is that
    # self-hosting being the whole of validation.
    #
    # ## Isolation
    #
    # The meta-domain is loaded once and its registry reused ; each bluebook is
    # judged in a fresh in-memory store so no domain can see another's records.
    module MetaValidator
      # **The folder is the chapter**. Files are grouped by the domain concept they
      # describe and every one reopens the same `Hecks.bluebook "Bluebook"`.
      # `BluebookBuilder.build` keeps one builder open per chapter name across
      # calls, so the sorted folder accumulates one domain. Adding or renaming a
      # concept file requires no second catalog here; deterministic filename
      # order is the source order exported to IR.
      GRAMMAR_DIR   = File.expand_path("../language/bluebook", __dir__).freeze
      GRAMMAR_FILES = Dir.glob(File.join(GRAMMAR_DIR, "*.bluebook")).freeze
      # Sibling artifact languages use the same folder-is-the-chapter rule.
      # Their arrays are discovered, sorted source sets—not filename catalogs.
      WORLD_GRAMMAR = Dir.glob(File.expand_path("../language/world/*.bluebook", __dir__)).freeze
      HECKSAGON_GRAMMAR = Dir.glob(File.expand_path("../language/hecksagon/*.bluebook", __dir__)).freeze
      # so is a port — whole-project table-unification survey, item #13's
      # remaining builders. Backs the new PortJudge door the same way
      # WORLD_GRAMMAR backs WorldJudge.
      PORT_GRAMMAR = File.expand_path("../language/port.bluebook", __dir__).freeze
      # so is an adapter — same reasoning, one file over. Backs AdapterJudge.
      ADAPTER_GRAMMAR = File.expand_path("../language/adapter.bluebook", __dir__).freeze
      # so is a translation — same reasoning, one file over. Backs
      # TranslationJudge.
      TRANSLATION_GRAMMAR = Dir.glob(File.expand_path("../language/translation/*.bluebook", __dir__)).freeze

      # ADR 0026's own seam: the core does not name its extension points.
      #
      # A sub-language chapter (Paging, so far the only one) is an ordinary
      # bluebook — declared with the same `aggregate`/`value_object`/
      # `attaches_to` words every domain has, judged through the language
      # the normal way, not bootstrapped raw the way GRAMMAR_FILES is. What
      # makes it special is only where it lives: any file in this directory
      # is discovered and loaded here, by the directory's own existence,
      # never by a name this file would have to know. Add a chapter here
      # and it is attached ; nothing in this file changes.
      ATTACHED_GRAMMAR_DIR = File.expand_path("../language/bluebook/attaches", __dir__).freeze

      # The chapters that are the language — loaded raw during bootstrap, then
      # judged through themselves and replaced by their own assembled graphs
      # (see grammar_registry). Each is named after its file : Bluebook describes
      # bluebooks (language/bluebook/) ; World describes worlds (world.bluebook),
      # and backs the WorldJudge door ; Hecksagon describes hecksagons
      # (hecksagon.bluebook) — declared for the same self-description reasons as
      # World, but without a judge door of its own : nothing dispatches a real
      # .hecksagon file through it yet, so HecksagonBuilder's own behavior is
      # unchanged. What this buys is what syntax.bluebook needed — a real shape
      # `subscribe`'s `fills: "subscriptions"` can point at — not new validation
      # on top of the corpus's existing .hecksagon files.
      LANGUAGE_CHAPTERS = %w[Bluebook World Hecksagon].freeze

      # The meta-domain is itself a bluebook. Judging it while loading it would
      # recurse, so the load path marks the bootstrap and skips — but the skip
      # is only the first pass. Once every grammar file is loaded and merged,
      # grammar_registry judges the language through itself and keeps the
      # assembled result (the fixpoint, made load-bearing).
      #
      # @return [Boolean] true while the language's own grammar is loading
      def self.bootstrapping? = @bootstrapping

      # A chapter may be split across files, so it cannot be judged until
      # every file has been read.
      #
      # `BluebookBuilder.build` already merges — `registry.bluebook_builder
      # (name)` memoises one builder per chapter name, so nine files each
      # saying `Hecks.bluebook "Bluebook"` accumulate into one. What it
      # also does is call `MetaValidator.call` once per file, judging a
      # chapter that is still eight files short: `Aggregate`'s reference
      # to `Bluebook` dangles because `Bluebook` has not been declared
      # yet, and the load dies.
      #
      # The language's own grammar has always needed this and got it
      # privately, through `@bootstrapping` (see load_grammar_into) —
      # which is exactly why the language could not boot the way the
      # domains it describes boot. This is that same two-phase load,
      # available to anything: `Folder#load_domain` reads every
      # `*.bluebook` inside `defer`, then judges each composed chapter
      # once, before hecksagons and worlds load (DOMAIN_ORDER already
      # puts every chapter ahead of those).
      #
      # Only chapters declared inside the window are judged afterwards.
      # Re-judging one already assembled — a framework member pulled in
      # earlier by `uses_framework`, say — would re-run Assembly and hand
      # out a second set of classes for a graph something already holds.
      def self.deferring? = @deferring

      # Runs the block with `deferring?` true for its duration, so a loader
      # reading a chapter's many files can queue them for `judge_deferred!`
      # instead of having each file judged, incomplete, on its own.
      #
      # @yield the caller's load of one chapter's files
      # @return [Object] whatever the block returns
      def self.defer
        previous   = @deferring
        @deferring = true
        yield
      ensure
        @deferring = previous
      end

      # Chapter names `call` queued while `deferring?` was true.
      #
      # @return [Array<String>] chapter names queued by `call` while `deferring?` was true
      def self.deferred_chapters = @deferred_chapters ||= []

      # Judges every chapter `call` queued while `deferring?` was true, now that every
      # file of each has loaded.
      #
      # @param registry [Runtime::Registry, nil] the registry the deferred chapters were
      #   loaded into; a falsy registry judges nothing
      # @return [Array<String>, nil] the chapter names judged, or nil when `registry` is falsy
      # @raise [DSL::Malformed] if a deferred chapter is not well formed (see `call`)
      def self.judge_deferred!(registry)
        pending = deferred_chapters.uniq
        @deferred_chapters = []
        return unless registry

        pending.each do |name|
          chapter = registry.bluebook(name)
          next unless chapter

          # A bare chapter-given left pending by any file of this
          # chapter (`AggregateBuilder#pending_chapter_given`) resolves
          # first — before anything below reads a `Given`'s fields.
          # `registry.bluebook_builder(name)` is the same instance every
          # one of this chapter's own files built onto (`#self.build`'s
          # own comment); it is guaranteed already open here, since it
          # is what produced `chapter` in the first place — the block is
          # dead code, never actually invoked.
          builder = registry.bluebook_builder(name) { raise "internal: no open builder for #{name}" }
          builder.resolve_pending_chapter_givens!
          # The entity-scoped analogue, one level down — same reason,
          # same timing: a bare entity-level given left pending by any
          # file of this chapter (`EntityBuilder#pending_chapter_entity_
          # given`) must resolve before anything below reads a piece's
          # own `Given` fields too.
          builder.resolve_pending_chapter_entity_givens!

          # `BluebookBuilder#build` skipped its own whole-chapter battery
          # (hops, projected fields, correlation keys, event shapes,
          # `with:` projections) for every file of this chapter while
          # `deferring?` was true, the same reason `call` below queued
          # instead of judging — each of those checks needs every file
          # loaded first (see `BluebookBuilder.validate_assembled!`'s own
          # comment). `chapter` here is exactly that: whatever the last
          # file's own `add_bluebook` left in the registry, which by now
          # holds every aggregate/policy/process_manager the whole
          # chapter declares. Run once, here, instead of once per file.
          DSL::BluebookBuilder.validate_assembled!(chapter)
          registry.add_bluebook(call(chapter))
        end
      end

      # `&& !@forcing_fixpoint` — see `while_forcing_fixpoint` below, whose own
      # window must win even while a growth spec's `while_disabled` is open,
      # for the reason recorded there. Otherwise the same stack-restore shape
      # `while_shadow_parsing`/`while_forcing_fixpoint` use, not a bare env
      # toggle — a bare toggle (`ENV["HECKS_META_VALIDATION"] == "off"`, read
      # directly, with no `previous`/`ensure` of its own) is not equivalent,
      # because the gap between "bare toggle" and "stack-restore" is not
      # cosmetic: a test's temporary window could reach code it was never
      # meant to touch. If `grammar_registry`'s one-time lazy build (below)
      # happened to land inside that window, every language chapter got
      # cached in its raw, never-judged form for the rest of the process —
      # `unmark_scalar`'s String->Integer/Boolean fix (assembly/marks.rb)
      # never ran, so a `Command`'s own `required: true` stayed
      # `required: "true"` forever after, permanently memoized. Found live:
      # an intermittent, parallel_rspec-only ir_golden_spec.rb failure,
      # order-dependent on whether identifier_numeric_coercion_growth_spec.rb's
      # disabled-validation window raced the one lazy build in its own worker
      # process — reproduced in isolation by disabling validation before the
      # first `grammar_registry` call. `&& !@forcing_fixpoint` was the first
      # fix and is kept ; converting `@disabled` itself to this shape closes
      # the gap for every other caller of `while_disabled`, not just the one
      # race that was actually observed — nothing outside this file reads
      # `ENV["HECKS_META_VALIDATION"]` any more (confirmed: every one of the
      # dozen growth specs that once hand-rolled `previous = ENV[...] ;
      # ENV[...] = "off" ; ... ; ensure ENV[...] = previous` now calls
      # `while_disabled` instead), so there is no bare global left to race.
      #
      # @return [Boolean] true while validation is off and the fixpoint judge is not forcing it on
      def self.disabled? = @disabled && !@forcing_fixpoint

      # The same stack-restore shape `while_shadow_parsing`/`while_forcing_
      # fixpoint` use. This toggle's real, intended use is a growth spec
      # that boots a scratch bluebook from a tempfile and wants the runtime
      # behaviour without the validation overhead ; that is always a single
      # bounded window around one boot, never a flag meant to survive past
      # it, so the flag itself is scoped in the same `previous`/`ensure`
      # shape rather than a plain assignment a caller could forget to undo.
      #
      # @yield the caller's scratch boot, with `disabled?` true for its duration
      # @return [Object] whatever the block returns
      def self.while_disabled
        previous  = @disabled
        @disabled = true
        yield
      ensure
        @disabled = previous
      end

      # ADR 0025's own prerequisite (docs/dsl-work-slices.md, S0a): a word
      # a later slice removes from the live grammar must still parse
      # frozen era text — `EraGuard.shadow_parse` (runtime/era_guard.rb)
      # is a plain `Kernel.eval` of stored source, run at boot, at mint,
      # and during tamper detection, against whatever grammar is live
      # today, not whatever grammar was live when that text was written.
      # Judging it again here would refuse history the day a spelling it
      # used is removed — proved with a rule that already lives only in
      # the meta-domain, never duplicated as a builder's own `raise
      # Malformed` (`vision`'s own comment: "moved to the language").
      #
      # Mirrors `defer`'s own stack-restore shape, not `disabled?`'s bare
      # env toggle — this must never leak past the one shadow-parse call
      # that set it, the same reason `ConstShim.with`/`.active?`
      # (bluebook/dsl/const_shim.rb) restores in an `ensure` rather than
      # being flipped and left.
      #
      # @return [Boolean] true while a shadow-parse of frozen era text is in progress
      def self.shadow_parsing? = @shadow_parsing

      # Runs the block with `shadow_parsing?` true for its duration, so a
      # frozen era's stored source is not re-judged against the live grammar.
      #
      # @yield the one `Kernel.eval` of stored source (`EraGuard.shadow_parse`)
      # @return [Object] whatever the block returns
      def self.while_shadow_parsing
        previous        = @shadow_parsing
        @shadow_parsing = true
        yield
      ensure
        @shadow_parsing = previous
      end

      # The same stack-restore shape `while_shadow_parsing` uses, for the
      # same reason: whatever this wraps must never see `disabled?` answer
      # true, however a test elsewhere has the env toggle set at that
      # exact moment. Only `grammar_registry`'s own one-time build (below)
      # wraps itself in this — nothing else needs it, and nothing else
      # should reach for it just to dodge `disabled?` for a domain
      # bluebook, which is precisely the toggle's real, intended use.
      #
      # @yield the language's own fixpoint judge
      # @return [Object] whatever the block returns
      def self.while_forcing_fixpoint
        previous          = @forcing_fixpoint
        @forcing_fixpoint = true
        yield
      ensure
        @forcing_fixpoint = previous
      end

      # The same bluebook judged twice gets the same verdict, and a suite reloads
      # its fixtures constantly — banking alone is ~200 dispatches per build.
      # Keyed on the IR itself, so a changed bluebook is always re-judged.
      #
      # @return [Hash{String => Object}] verdicts keyed by a SHA-256 digest of the judged
      #   input; each value is an `Array<String>` of refusals (world/port/adapter/translation)
      #   or a `{refusals:, declaration:}` Hash (a full bluebook chapter, see `hold`)
      def self.verdicts = @verdicts ||= {}

      # A world is not a bluebook, so it gets its own door. Same judge, same
      # meta-domain registry — a different artifact and a different language file.
      #
      # @param world [Bluebook::World] the built world to judge
      # @return [Bluebook::World] `world` unchanged, once judged well formed
      # @raise [DSL::Malformed] if `world`'s settings refuse the language's rules
      def self.call_world(world)
        return world if disabled? || bootstrapping? || shadow_parsing?

        key = Digest::SHA256.hexdigest(JSON.generate([world.domain, world.realm, world.latest, world.settings]))
        refusals = verdicts[key] ||= WorldJudge.new(world).refusals
        return world if refusals.empty?

        raise DSL::Malformed,
              "#{world.domain}'s world is not well formed; #{refusals.join('; ')}"
      end

      # A port is not a bluebook either — same door shape as call_world,
      # one artifact over. Whole-project table-unification survey, item
      # #13's remaining builders.
      #
      # @param port [Bluebook::Port] the built port to judge
      # @return [Bluebook::Port] `port` unchanged, once judged well formed
      # @raise [DSL::Malformed] if `port` refuses the language's rules
      def self.call_port(port)
        return port if disabled? || bootstrapping? || shadow_parsing?

        key = Digest::SHA256.hexdigest(JSON.generate([port.name, port.verb, port.signal]))
        refusals = verdicts[key] ||= PortJudge.new(port).refusals
        return port if refusals.empty?

        raise DSL::Malformed,
              "#{port.name}'s port is not well formed; #{refusals.join('; ')}"
      end

      # An adapter is not a bluebook either — same door shape, one more
      # artifact over. Whole-project table-unification survey, item
      # #13's remaining builders.
      #
      # @param adapter [Bluebook::Adapter] the built adapter to judge
      # @return [Bluebook::Adapter] `adapter` unchanged, once judged well formed
      # @raise [DSL::Malformed] if `adapter` refuses the language's rules
      def self.call_adapter(adapter)
        return adapter if disabled? || bootstrapping? || shadow_parsing?

        key = Digest::SHA256.hexdigest(JSON.generate([adapter.name, adapter.port, adapter.fields, adapter.secrets]))
        refusals = verdicts[key] ||= AdapterJudge.new(adapter).refusals
        return adapter if refusals.empty?

        raise DSL::Malformed,
              "#{adapter.name}'s adapter is not well formed; #{refusals.join('; ')}"
      end

      # A translation is not a bluebook either — same door shape, one more
      # artifact over (a `translations/*.bluebook` edge — `data_translation`'s
      # own real, established convention; there is no separate extension).
      # TranslationJudge walks the whole built translation (every nested
      # aggregate's own rule table) in one pass — only
      # TranslationBuilder's own top-level `build` calls this;
      # TranslationAggregateBuilder#build stays a plain struct constructor,
      # the same way `WorldJudge` judges every `Wiring` a `.world` declares
      # in one pass over `World::World.Declare`'s own caller, not from a
      # separate door per binding. Whole-project table-unification survey,
      # item #13's remaining builders.
      #
      # @param translation [Bluebook::Translation] the built translation to judge
      # @return [Bluebook::Translation] `translation` unchanged, once judged well formed
      # @raise [DSL::Malformed] if `translation` refuses the language's rules
      def self.call_translation(translation)
        return translation if disabled? || bootstrapping? || shadow_parsing?

        # `Translation`/`TranslationAggregate` are plain classes (attr_
        # reader, not Struct — lib/hecks/bluebook/translation.rb),
        # so neither carries a `.to_h`; `.inspect` is JSON-safe (a plain
        # string) and, unlike a Struct's own memoization-friendly `.to_h`,
        # doesn't need one — the small correctness cost is that its
        # embedded object-id prefix makes two structurally-identical
        # translations hash differently, so `verdicts` simply never
        # cache-hits here (an efficiency loss, not a correctness one —
        # judged fresh every time instead of memoized).
        key = Digest::SHA256.hexdigest(translation.inspect)
        refusals = verdicts[key] ||= TranslationJudge.new(translation).refusals
        return translation if refusals.empty?

        raise DSL::Malformed,
              "#{translation.domain}'s translation is not well formed; #{refusals.join('; ')}"
      end

      # The language hands the graph back.
      #
      # Simply returning the bluebook it was given — dispatch every declaration
      # in, collect refusals, throw the records away — is all judging needs, and
      # exactly why the language could only validate that way. This returns what
      # the meta-domain holds instead, assembled into the graph the runtime runs.
      # The builder's own object graph exists only to be dispatched; nothing
      # keeps it.
      #
      # `Hecks.bluebook` registers whatever comes back from here, so this one line
      # is the difference between a language that checks a domain and a language
      # that is the source of one.
      #
      # What is cached is the declarations, not the graph. A hash carries no Ruby
      # classes, so a second load of the same chapter re-assembles fresh ones —
      # which is the behaviour `Namespace.install` and `spec/construct_spec` both
      # expect. Caching the graph would hand two boots the same classes.
      # The language is the source. This is the line that makes it one.
      #
      # `Hecks.bluebook` registers whatever comes back from here, so returning the
      # assembled graph rather than the bluebook it was handed is the whole swap: the
      # runtime runs what the meta-domain holds. The builder's own graph exists only
      # to be dispatched in ; nothing keeps it.
      #
      # It stayed unlanded for one wrong belief, worth naming because it looked so
      # much like a wall: that the language may only hold what `to_h` carries.
      # `ReadModel#to_h` omitted a read model's filters until 2026-08-11, so
      # read-model filtering seemed impossible to read back —
      # and hoisted policies lost which head declared them for the same reason.
      # But `to_h` is a projection and the language is the
      # source. They must agree about everything to_h spells ; they need not be the
      # same size. Both were held even before the wire format carried them, as
      # declarations the wire format didn't yet see.
      #
      # Update, 2026-08-11: the wire format did move, on purpose, for a reason
      # unrelated to this file — a Rust-codegen task needed `wheres`/
      # `order_by`/`limit` on the wire to compile a read model's real declared
      # filtering, and the boundary described above was never load-bearing for
      # this mechanism (`option_rows`/`filter_options` in meta_validator/
      # readings.rb read `node.wheres`/`node.order_by`/`node.limit` off the
      # live object directly, never off `to_h`), so extending `to_h` changed
      # nothing here. `ReadModel#to_h` now spells all three explicitly, the
      # same mechanism `Query#to_h` already used — purely additive, still
      # agreeing with the language about everything it spells.
      #
      # What is cached is the declarations, not the graph. A hash carries no Ruby
      # classes, so a second load of the same chapter assembles fresh ones — which is
      # what `Namespace.install` and `spec/construct_spec` both expect. Caching the
      # graph would hand two boots the same classes.
      #
      # @param bluebook [Bluebook::Chapter] the built chapter to judge
      # @return [Bluebook::Chapter] the chapter assembled from the meta-domain's own
      #   records, or `bluebook` unchanged while disabled, bootstrapping, shadow-parsing,
      #   or deferring
      # @raise [DSL::Malformed] if `bluebook` is not well formed
      def self.call(bluebook)
        return bluebook if disabled? || bootstrapping? || shadow_parsing?

        if deferring?
          deferred_chapters << bluebook.hecks_name
          return bluebook
        end

        key = Digest::SHA256.hexdigest(JSON.generate(bluebook.to_h))
        held = verdicts[key] ||= hold(bluebook)

        unless held[:refusals].empty?
          raise DSL::Malformed,
                "#{bluebook.hecks_name} is not a well-formed bluebook; #{held[:refusals].join('; ')}"
        end

        Assembly.call(held[:declaration])
      end

      # Dispatch it in and read it back. A refused chapter has no declarations to
      # read — the records are half-written by definition — so it carries refusals
      # and nothing else.
      #
      # @param bluebook [Bluebook::Chapter] the built chapter to judge
      # @return [Hash{Symbol => Object}] `{refusals:}` when `bluebook` is refused, or
      #   `{refusals: [], declaration:}` (a `Reconstruction.of` Hash) once it is held
      # @raise [NameError] if `Reconstruction.of` cannot find the chapter it was just
      #   judged into — see `Reconstruction`'s own comment; looks like a bug
      def self.hold(bluebook)
        judge = Judge.new(bluebook)
        return { refusals: judge.refusals } unless judge.refusals.empty?

        { refusals: [], declaration: Reconstruction.of(judge.runtime, bluebook.hecks_name) }
      end

      # The language's own grammar, loaded once and judged through itself.
      #
      # @return [Runtime::Registry] the memoised registry holding every language chapter
      def self.grammar_registry
        @grammar_registry ||= begin
          registry = load_grammar_into(Runtime::Registry.new)
          # Assigned before the fixpoint judge below: judging re-enters
          # grammar_registry through fresh_runtime (judge.rb) and Plan.for
          # (judge.rb, reconstruction.rb) — a bare ||= would still be nil
          # while its right-hand side evaluates, and recurse forever. That
          # reentrancy window is real: a caller landing here before the
          # fixpoint/attach below have run sees the same registry object,
          # correctly, but one still missing the attached chapters (Paging's
          # `attaches_to` among them) — see grammar_registry_ready? below.
          @grammar_registry = registry
          # **The fixpoint made load-bearing**. The bootstrap loaded the language
          # raw ; now the language judges itself, its records are read back,
          # and the assembled graph replaces the raw one — so every bluebook
          # judged from here on is judged by the language the language itself
          # produced. Outside load_grammar_into on purpose : its ensure clears
          # @bootstrapping, and call() must see bootstrapping? == false to do
          # anything at all. `while_forcing_fixpoint`-wrapped so a growth
          # spec's own `while_disabled` window can never leave this
          # one-time build cached in its raw, never-judged form — see
          # `disabled?`'s own comment.
          while_forcing_fixpoint do
            LANGUAGE_CHAPTERS.each { |name| registry.add_bluebook(call(registry.bluebook(name))) }
            load_attached_grammar_into(registry)
          end
          # Stamped last, keyed by this registry's own identity rather than
          # a bare boolean — a manual reset (fixpoint_spec.rb's own
          # `@grammar_registry = nil`) makes @grammar_registry not equal
          # this object_id again until a fresh build finishes, so a stale
          # "ready" from the previous cycle can never leak into the next.
          @grammar_ready_for = registry.object_id
          registry
        end
      end

      # A reentrant call during the fixpoint/attach window above gets a
      # real, correctly-mutating registry object back — no infinite loop,
      # no wrong data for that caller's own purposes. But anything that
      # memoizes a snapshot derived from it must not lock that snapshot
      # in forever : this is one signal such a cache can check. Found
      # live — SyntaxBoot.call had cached a Query keyword list missing
      # every Paging-attached word (limit/offset/cursor/nulls) because
      # something called it inside this exact window.
      #
      # SyntaxBoot.call no longer uses this. Gating its cache on "the
      # whole registry is finished" meant nothing was cached for the
      # entire window, and the window is not narrow — every word routed
      # through `word_gate_dispatch` while the language judged itself
      # re-ran the ~284-dispatch syntax boot (42 times, 32 seconds, per
      # process — see SyntaxBoot.call's own comment). It keys its cache
      # on the registry's chapter set instead, which is the actual input
      # the snapshot is a function of. Kept here for any other derived
      # cache that genuinely needs "is the build finished" rather than
      # "have my inputs changed".
      #
      # @return [Boolean] true once `grammar_registry`'s fixpoint judge and attach have run
      def self.grammar_registry_ready?
        @grammar_registry && @grammar_ready_for == @grammar_registry.object_id
      end

      # Attached chapters load after the fixpoint, not during bootstrap —
      # they are declared in the language the language just finished
      # judging itself through, so they are ordinary bluebooks, judged the
      # ordinary way (`Hecks.bluebook` → `BluebookBuilder#build` →
      # `MetaValidator.call`, `bootstrapping?` already false). A directory
      # with nothing in it loads nothing ; this is a no-op until a chapter
      # is added there.
      #
      # @param registry [Runtime::Registry] the registry to load attached chapters into
      # @return [Array<String>] the attached `.bluebook` file paths loaded, in glob order
      def self.load_attached_grammar_into(registry)
        Hecks.with_registry(registry) do
          Dir.glob(File.join(ATTACHED_GRAMMAR_DIR, "*.bluebook")).each { |file| Kernel.load(file) }
        end
      end

      # The one place the grammar's own boot sequence is spelled — ports, the
      # memory/prism adapters, the (now nine-file) chapter itself, then the
      # sibling world grammar. `grammar_registry` uses this for its memoised
      # singleton ; anything that needs an isolated registry (a spec wanting a
      # fresh store per example, say) calls this directly instead of hand-
      # copying the sequence.
      #
      # The bootstrap guard lives here, not just around the singleton. Splitting
      # the chapter into several files means each file's own `Hecks.bluebook
      # "Bluebook"` call now runs `BluebookBuilder#build` once per file — and
      # `MetaValidator.call` judges whatever it is handed unless `bootstrapping?`
      # is true. A caller that loaded the grammar files by hand into its own
      # registry, without this guard, would get each file dispatched and judged
      # alone the moment it loaded — and a lone file like `aggregate.bluebook`
      # refuses immediately, since `Aggregate.Attribute` references `ValueObject`
      # and `Aggregate.Holds` references `Entity`, both declared in later files.
      # Every caller of the grammar must go through here for exactly that reason.
      #
      # @param registry [Runtime::Registry] the registry to load the language's grammar into
      # @return [Runtime::Registry] `registry`, once every grammar file has loaded
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

      # A fresh store per bluebook. The registry memoises repositories, so
      # reusing it let every bluebook see the records of every bluebook judged
      # before it. The parsed grammar is reused ; only the records are cleared.
      # (During grammar_registry's own fixpoint judge this clear runs on the
      # singleton mid-memoisation — harmless for the same reason : the grammar
      # is what is kept, the records were never meant to survive a judging.)
      # No `bind_runtime` here : judging dispatches by FQN and never opens the
      # door, and binding would re-install the language's own facade constants
      # once per judged chapter.
      #
      # @return [Runtime::Dispatcher] a dispatcher over the grammar registry, with its
      #   own record store cleared
      def self.fresh_runtime
        registry = grammar_registry
        registry.instance_variable_set(:@repositories, {})
        Runtime::Dispatcher.new(registry)
      end
    end
  end
end
