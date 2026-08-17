require "digest"
require "json"

module Hecksagain
  module Bluebook
    # Judges a bluebook by DISPATCHING it into the language declared in itself.
    #
    # `lib/hecksagain/language/bluebook/` declares what a bluebook IS —
    # Chapter, Root, Verb, Shape, Ask, Piece, and the rest, split across nine
    # files by function and merged into one chapter at load time (see
    # GRAMMAR_FILES below) — and carries the language's rules as `given` and
    # `invariant` rather than as `raise Malformed` scattered across seven
    # builder files. This replays a built IR into that domain and turns any
    # refusal into a Malformed, so the meta-domain is what actually judges
    # rather than a description sitting beside the code.
    #
    # Delete language/bluebook/ and validation stops. That is the whole
    # point : a self-description that only describes is indistinguishable from
    # enforcement, and the first version of this file was deleted for exactly
    # that reason.
    #
    # The meta-domain is loaded ONCE and its registry reused ; each bluebook is
    # judged in a fresh in-memory store so no domain can see another's records.
    module MetaValidator
      # THE CHAPTER, SPLIT BY FUNCTION, MERGED AT LOAD TIME. One 1973-line file
      # became nine, grouped by what each piece of the language IS (a root, what
      # it can do, what it is made of, what reacts to it, its closed vocabulary,
      # the read-back) rather than left as one undifferentiated block. Every file
      # opens the SAME `Hecks.bluebook "Bluebook" do ... end` ; `BluebookBuilder.build`
      # keeps one builder open per chapter name across calls (see its own comment),
      # so loading all nine in order accumulates one domain, not nine.
      #
      # ORDER IS AN EXPLICIT LIST, not a sorted glob. Declaration order is a fact
      # about the source — the golden IR fixture pins the exact sequence — and a
      # filename-alphabetical sort would not reproduce a deliberate, reviewed order
      # by accident. This is the array to edit when a file is added, removed, or
      # reordered.
      GRAMMAR_DIR   = File.expand_path("../language/bluebook", __dir__).freeze
      GRAMMAR_FILES = %w[bluebook aggregate behavior shape entity reaction vocabulary syntax projection]
                      .map { |name| File.join(GRAMMAR_DIR, "#{name}.bluebook") }.freeze
      # a world is a SIBLING artifact, described in its own file
      WORLD_GRAMMAR = File.expand_path("../language/world.bluebook", __dir__).freeze
      # so is a hecksagon — the same reasoning, one file over
      HECKSAGON_GRAMMAR = File.expand_path("../language/hecksagon.bluebook", __dir__).freeze

      # ADR 0026's OWN SEAM: THE CORE DOES NOT NAME ITS EXTENSION POINTS.
      #
      # A sub-language chapter (Paging, so far the only one) is an ORDINARY
      # bluebook — declared with the same `aggregate`/`value_object`/
      # `attaches_to` words every domain has, judged through the language
      # the normal way, not bootstrapped raw the way GRAMMAR_FILES is. What
      # makes it special is only where it LIVES: any file in this directory
      # is discovered and loaded here, by the directory's own existence,
      # never by a name this file would have to know. Add a chapter here
      # and it is attached ; nothing in this file changes.
      ATTACHED_GRAMMAR_DIR = File.expand_path("../language/bluebook/attaches", __dir__).freeze

      # The chapters that ARE the language — loaded raw during bootstrap, then
      # judged through themselves and replaced by their own assembled graphs
      # (see grammar_registry). Each is named after its file : Bluebook describes
      # bluebooks (language/bluebook/) ; World describes worlds (world.bluebook),
      # and backs the WorldJudge door ; Hecksagon describes hecksagons
      # (hecksagon.bluebook) — declared for the same self-description reasons as
      # World, but WITHOUT a judge door of its own : nothing dispatches a real
      # .hecksagon file through it yet, so HecksagonBuilder's own behavior is
      # unchanged. What this buys is what syntax.bluebook needed — a real shape
      # `subscribe`'s `fills: "subscriptions"` can point at — not new validation
      # on top of the corpus's existing .hecksagon files.
      LANGUAGE_CHAPTERS = %w[Bluebook World Hecksagon].freeze

      # The meta-domain is itself a bluebook. Judging it while loading it would
      # recurse, so the load path marks the bootstrap and skips — but the skip
      # is only the FIRST pass. Once every grammar file is loaded and merged,
      # grammar_registry judges the language through itself and keeps the
      # assembled result (the fixpoint, made load-bearing).
      def self.bootstrapping? = @bootstrapping

      # A CHAPTER MAY BE SPLIT ACROSS FILES, so it cannot be judged until
      # every file has been read.
      #
      # `BluebookBuilder.build` already MERGES — `registry.bluebook_builder
      # (name)` memoises one builder per chapter name, so nine files each
      # saying `Hecks.bluebook "Bluebook"` accumulate into one. What it
      # also does is call `MetaValidator.call` once PER FILE, judging a
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
      # Only chapters DECLARED INSIDE the window are judged afterwards.
      # Re-judging one already assembled — a framework member pulled in
      # earlier by `uses_framework`, say — would re-run Assembly and hand
      # out a second set of classes for a graph something already holds.
      def self.deferring? = @deferring

      def self.defer
        previous   = @deferring
        @deferring = true
        yield
      ensure
        @deferring = previous
      end

      def self.deferred_chapters = @deferred_chapters ||= []

      def self.judge_deferred!(registry)
        pending = deferred_chapters.uniq
        @deferred_chapters = []
        return unless registry

        pending.each do |name|
          chapter = registry.bluebook(name)
          registry.add_bluebook(call(chapter)) if chapter
        end
      end

      def self.disabled? = ENV["HECKSAGAIN_META_VALIDATION"] == "off"

      # ADR 0025's own prerequisite (docs/dsl-work-slices.md, S0a): a word
      # a later slice removes from the LIVE grammar must still parse
      # FROZEN ERA TEXT — `EraGuard.shadow_parse` (runtime/era_guard.rb)
      # is a plain `Kernel.eval` of stored source, run at boot, at mint,
      # and during tamper detection, against whatever grammar is live
      # TODAY, not whatever grammar was live when that text was written.
      # Judging it again here would refuse history the day a spelling it
      # used is removed — proved with a rule that already lives ONLY in
      # the meta-domain, never duplicated as a builder's own `raise
      # Malformed` (`vision`'s own comment: "moved to the language").
      #
      # Mirrors `defer`'s own stack-restore shape, not `disabled?`'s bare
      # env toggle — this must never leak past the one shadow-parse call
      # that set it, the same reason `ConstShim.with`/`.active?`
      # (bluebook/dsl/const_shim.rb) restores in an `ensure` rather than
      # being flipped and left.
      def self.shadow_parsing? = @shadow_parsing

      def self.while_shadow_parsing
        previous        = @shadow_parsing
        @shadow_parsing = true
        yield
      ensure
        @shadow_parsing = previous
      end

      # The same bluebook judged twice gets the same verdict, and a suite reloads
      # its fixtures constantly — banking alone is ~200 dispatches per build.
      # Keyed on the IR itself, so a CHANGED bluebook is always re-judged.
      def self.verdicts = @verdicts ||= {}

      # A world is not a bluebook, so it gets its own door. Same judge, same
      # meta-domain registry — a different artifact and a different language file.
      def self.call_world(world)
        return world if disabled? || bootstrapping? || shadow_parsing?

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
      # `ReadModel#to_h` omitted a read model's filters until 2026-08-11, so
      # read-model filtering seemed impossible to read back —
      # and hoisted policies lost which head declared them for the same reason.
      # But `to_h` is a PROJECTION and the language is the
      # SOURCE. They must agree about everything to_h spells ; they need not be the
      # same size. Both were held even before the wire format carried them, as
      # declarations the wire format didn't yet see.
      #
      # UPDATE, 2026-08-11: the wire format DID move, on purpose, for a reason
      # unrelated to this file — a Rust-codegen task needed `wheres`/
      # `order_by`/`limit` on the wire to compile a read model's real declared
      # filtering, and the boundary described above was never load-bearing for
      # THIS mechanism (`option_rows`/`filter_options` in meta_validator/
      # readings.rb read `node.wheres`/`node.order_by`/`node.limit` off the
      # live object directly, never off `to_h`), so extending `to_h` changed
      # nothing here. `ReadModel#to_h` now spells all three explicitly, the
      # same mechanism `Query#to_h` already used — purely additive, still
      # agreeing with the language about everything it spells.
      #
      # What is CACHED is the declarations, not the graph. A hash carries no Ruby
      # classes, so a second load of the same chapter assembles fresh ones — which is
      # what `Namespace.install` and `spec/construct_spec` both expect. Caching the
      # graph would hand two boots the same classes.
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
          registry = load_grammar_into(Runtime::Registry.new)
          # Assigned BEFORE the fixpoint judge below: judging re-enters
          # grammar_registry through fresh_runtime (judge.rb) and Plan.for
          # (judge.rb, reconstruction.rb) — a bare ||= would still be nil
          # while its right-hand side evaluates, and recurse forever.
          @grammar_registry = registry
          # THE FIXPOINT MADE LOAD-BEARING. The bootstrap loaded the language
          # raw ; now the language judges itself, its records are read back,
          # and the ASSEMBLED graph replaces the raw one — so every bluebook
          # judged from here on is judged by the language the language itself
          # produced. Outside load_grammar_into on purpose : its ensure clears
          # @bootstrapping, and call() must see bootstrapping? == false to do
          # anything at all.
          LANGUAGE_CHAPTERS.each { |name| registry.add_bluebook(call(registry.bluebook(name))) }
          load_attached_grammar_into(registry)
          registry
        end
      end

      # ATTACHED CHAPTERS LOAD AFTER THE FIXPOINT, NOT DURING BOOTSTRAP —
      # they are declared IN the language the language just finished
      # judging itself through, so they are ordinary bluebooks, judged the
      # ordinary way (`Hecks.bluebook` → `BluebookBuilder#build` →
      # `MetaValidator.call`, `bootstrapping?` already false). A directory
      # with nothing in it loads nothing ; this is a no-op until a chapter
      # is added there.
      def self.load_attached_grammar_into(registry)
        Hecksagain.with_registry(registry) do
          Dir.glob(File.join(ATTACHED_GRAMMAR_DIR, "*.bluebook")).sort.each { |file| Kernel.load(file) }
        end
      end

      # THE ONE PLACE THE GRAMMAR'S OWN BOOT SEQUENCE IS SPELLED — ports, the
      # memory/prism adapters, the (now nine-file) chapter itself, then the
      # sibling world grammar. `grammar_registry` uses this for its memoised
      # singleton ; anything that needs an ISOLATED registry (a spec wanting a
      # fresh store per example, say) calls this directly instead of hand-
      # copying the sequence.
      #
      # THE BOOTSTRAP GUARD LIVES HERE, not just around the singleton. Splitting
      # the chapter into several files means each file's own `Hecks.bluebook
      # "Bluebook"` call now runs `BluebookBuilder#build` once per file — and
      # `MetaValidator.call` judges whatever it is handed unless `bootstrapping?`
      # is true. A caller that loaded the grammar files by hand into its own
      # registry, without this guard, would get each file DISPATCHED AND JUDGED
      # ALONE the moment it loaded — and a lone file like `aggregate.bluebook`
      # refuses immediately, since `Aggregate.Attribute` references `ValueObject`
      # and `Aggregate.Holds` references `Entity`, both declared in later files.
      # Every caller of the grammar must go through here for exactly that reason.
      def self.load_grammar_into(registry)
        @bootstrapping = true
        Hecksagain.with_registry(registry) do
          Kernel.load(File.expand_path("../ports/persistence.port", __dir__))
          Kernel.load(File.expand_path("../ports/extraction.port", __dir__))
          Kernel.load(File.expand_path("../adapters/driven/memory.adapter", __dir__))
          Kernel.load(File.expand_path("../adapters/driven/prism.adapter", __dir__))
          GRAMMAR_FILES.each { |file| Kernel.load(file) }
          Kernel.load(WORLD_GRAMMAR)
          Kernel.load(HECKSAGON_GRAMMAR)
        end
        registry
      ensure
        @bootstrapping = false
      end

      # A FRESH STORE per bluebook. The registry memoises repositories, so
      # reusing it let every bluebook see the records of every bluebook judged
      # before it. The parsed grammar is reused ; only the records are cleared.
      # (During grammar_registry's own fixpoint judge this clear runs on the
      # singleton mid-memoisation — harmless for the same reason : the grammar
      # is what is kept, the records were never meant to survive a judging.)
      # No `bind_runtime` here : judging dispatches by FQN and never opens the
      # door, and binding would re-install the language's own facade constants
      # once per judged chapter.
      def self.fresh_runtime
        registry = grammar_registry
        registry.instance_variable_set(:@repositories, {})
        Runtime::Dispatcher.new(registry)
      end
    end
  end
end
