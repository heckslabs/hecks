require_relative "word_gate"
require_relative "bluebook_builder/validation"
module Hecks
  module Bluebook
    module DSL
      # The `Hecks.bluebook "Name" do ... end` receiver — the chapter-level
      # builder collecting every `aggregate`/`read_model`/`policy`/
      # `process_manager` a chapter declares, plus the chapter-wide named-
      # given pools those thread down into (see `#aggregate_impl`'s own
      # comment). `.build` reuses the SAME open builder instance across
      # several files sharing one chapter name (`self.build`'s own comment),
      # so a chapter split across files accumulates rather than each file
      # silently replacing the last.
      class BluebookBuilder
        GRAMMAR_CONTEXT = "Bluebook".freeze

        include WordGate
        extend Validation

        attr_reader :classification

        def initialize(name, version: nil)
          @name       = name
          @version    = version
          @aggregates       = []
          @read_models      = []
          @policies         = []
          @process_managers = []
          # THE ROOT of the CHAPTER-WIDE given pool — one level wider
          # than `AggregateBuilder`'s own `@entity_named_givens` (S10
          # extended across an aggregate's whole entity tree, earlier
          # this arc). See `#given`'s own comment for what this closes.
          @chapter_named_givens = {}
          # EVERY BARE CHAPTER-GIVEN REFERENCE THIS CHAPTER'S OWN FILES
          # LEFT UNRESOLVED SO FAR — threaded into every aggregate the
          # same way `@chapter_named_givens` is. See
          # `AggregateBuilder#pending_chapter_given`'s own comment for
          # what queues here and `#resolve_pending_chapter_givens!`,
          # below, for where it drains.
          @chapter_pending_givens = []
          # ONE LEVEL WIDER STILL — the CHAPTER-WIDE, ENTITY-SCOPED pool
          # (the piece analogue of `@chapter_named_givens`, above). See
          # `EntityBuilder#given_impl`'s own comment for what this
          # closes; `docs/implemented/resolution-rules/
          # chapter-entity-given.md` for the full algorithm.
          @chapter_entity_named_givens   = {}
          @chapter_entity_pending_givens = []
        end

        # Chapter metadata belongs to the composed folder, not whichever file
        # happened to sort first. A later concept file may be the one carrying
        # the version header; adopt it into the already-open chapter builder.
        # Two different versions are a real contradiction, not load order.
        def adopt_version(version)
          return if version.nil?
          if @version && @version.to_s != version.to_s
            raise Malformed,
                  "#{@name} declares both version #{@version.inspect} and #{version.inspect}"
          end

          @version = version
        end
        private :adopt_version

        def vision(value)
          # moved to the language: Vision invariant, on Chapter.Declare

          @vision = value
        end

        # A domain's own identity can change — this names what it used to
        # be, so the storage layer can recognize its own history under the
        # old name instead of minting a brand-new lineage from nothing.
        def formerly_known_as(value) = @formerly_known_as = value.to_s

        # A SUB-LANGUAGE NAMES WHERE IT LANDS. ADR 0026's own seam: the core
        # grammar does not name its extension points, so this chapter names
        # ITSELF onto them instead — the core contexts (e.g. "Query",
        # "ReadModel") whose own admitted words this chapter's `Syntax`
        # aggregate contributes rows for. Variadic, and accumulating across
        # calls the same reason `identified_by`/`group_by` are: nothing here
        # requires one call to name every context at once.
        # RENAMED FROM `attaches_to` — item #13's full metaprogrammed
        # dispatch (slice 4c). Not bootstrap-reachable (only sub-language
        # chapters like Paging use it; the CORE chapters never describe
        # themselves with it).
        def attaches_to_impl(*contexts) = (@attaches_to ||= []).concat(contexts.map(&:to_s))

        def core       = @classification = :core
        def supporting = @classification = :supporting
        def generic    = @classification = :generic

        # `@chapter_named_givens` is threaded into every aggregate this
        # chapter builds — see `AggregateBuilder#given`'s own comment
        # for the sharing this enables; NOT a new top-level DSL word
        # itself (an aggregate's own EXISTING `given` already both
        # declares locally and write-throughs here as a side effect,
        # the identical shape `EntityBuilder#given`'s own write-through
        # to its owner aggregate's pool already takes — no new spelling
        # for "declare a precondition," one level wider, same word).
        # RENAMED FROM `aggregate` — item #13's full metaprogrammed
        # dispatch (slice 4c). Bootstrap-reachable (every core/attached
        # chapter's own top-level shape is written with it), so also
        # named in GenericDispatch::BOOTSTRAP_CALLS_FALLBACK.
        def aggregate_impl(name, &)
          @aggregates << AggregateBuilder.build(name, chapter_named_givens:          @chapter_named_givens,
                                                      chapter_pending_givens:        @chapter_pending_givens,
                                                      chapter_entity_named_givens:   @chapter_entity_named_givens,
                                                      chapter_entity_pending_givens: @chapter_entity_pending_givens, &)
        end

        # `read_model` is the word (ADR 0025 reverts `report` — the IR
        # construct, the registry API, and the docs filename all said
        # `read_model` the whole time; no era was ever minted under
        # `report`, so this is history and source agreeing again). `report`
        # stays answered under `MetaValidator.shadow_parsing?` (S0a's own
        # bridge) for the same reason `has_many` does — frozen era text
        # that used it must keep booting; live source refuses it, naming
        # the replacement.
        def read_model(name, &)
          # A read model gathers heads from SEVERAL aggregates, so no single head
          # declares it — the chapter does. Its owner is stamped in `build`, where
          # the chapter namespace exists.
          @read_models << ReadModelBuilder.build(name, &)
        end

        def report(name, &)
          return read_model(name, &) if MetaValidator.shadow_parsing?

          raise Malformed, "report is gone — read_model is the word now"
        end

        def policy(name, &)
          @policies << PolicyBuilder.build(name, &)
        end

        def process_manager(name, &)
          @process_managers << ProcessManagerBuilder.build(name, &)
        end

        def build
          # The chapter is the top of the construct chain — `Bluebook` is a
          # ROOT, and its constructor stamps every aggregate and read model with
          # itself as owner, so every `hecks_fqn` below resolves by walking up
          # to it. No constants are installed at load time : the public door is
          # a per-boot projection, installed by `Loader.bind_runtime` once a
          # dispatcher exists to close over (facade/surface.rb).
          bluebook = Bluebook::Chapter.new(name: @name, version: @version, vision: @vision,
                                           aggregates: @aggregates,
                                           read_models: @read_models,
                                           policies: @aggregates.flat_map(&:policies) + @policies,
                                           process_managers: @process_managers,
                                           classification: @classification,
                                           formerly_known_as: @formerly_known_as,
                                           attaches_to: @attaches_to || [])

          # SAME REASON, SAME GATE — a bare chapter-given may still be
          # pending (see `AggregateBuilder#pending_chapter_given`) if a
          # file that would resolve it hasn't loaded yet; resolving now
          # would see the same incomplete `@chapter_named_givens`
          # `validate_assembled!` below would. Deferred to
          # `MetaValidator.judge_deferred!` the same way, and BEFORE
          # `validate_assembled!` there — nothing downstream should ever
          # read an unresolved placeholder's fields.
          resolve_pending_chapter_givens! unless MetaValidator.deferring?
          resolve_pending_chapter_entity_givens! unless MetaValidator.deferring?

          # A CHAPTER MAY BE SPLIT ACROSS FILES (see `self.build`'s own
          # comment). Every check below needs the WHOLE chapter present —
          # a hop, a projection, a correlation key or an event shape can
          # equally name a construct declared in a file that has not
          # loaded yet, and `@aggregates`/`@process_managers` here are
          # only ever as complete as whatever has loaded SO FAR. So,
          # exactly like `MetaValidator.call` below, this is skipped
          # while `MetaValidator.defer` is loading the chapter's files
          # and run once instead — by `MetaValidator.judge_deferred!`,
          # against the fully assembled chapter — after the last one
          # loads. A single-file chapter (still the common case) never
          # sees `deferring?` true here at all, so its own checks still
          # run inline, exactly as before.
          self.class.validate_assembled!(bluebook) unless MetaValidator.deferring?

          # The language judges the bluebook, in the language. Last, so the
          # meta-domain sees a fully built IR — the whole-document rules need
          # every declaration present, which is why they cannot be givens fired
          # at declaration time.
          MetaValidator.call(bluebook)
        end

        # THE OTHER HALF OF A CHAPTER-WIDE `given` REFERENCE —
        # `AggregateBuilder#pending_chapter_given` recognised an
        # unresolved bare reference and deferred it here, unable to
        # check further: a later file in this SAME chapter might still
        # declare the real thing. Runs once every file has loaded,
        # against the now-complete `@chapter_named_givens` pool — the
        # IDENTICAL lookup `reference_named_chapter_given` already does,
        # just late enough to see every aggregate's own declarations,
        # not only the ones loaded before the referencing one.
        #
        # MUTATES each placeholder `Given` IN PLACE rather than
        # replacing it — it is already embedded, by Ruby object
        # reference, in the referencing aggregate's own `preconditions`
        # and in any command (same aggregate) that separately
        # bare-referenced the same description, so there is nothing
        # downstream holding a second, now-stale copy to update.
        # Instance-level (not `self.`, unlike `validate_assembled!`) —
        # unlike that battery, this needs `@chapter_named_givens` itself,
        # which only exists on the builder instance still open for this
        # chapter (`MetaValidator.judge_deferred!` reaches it via
        # `registry.bluebook_builder(name)`, guaranteed already present).
        def resolve_pending_chapter_givens!
          @chapter_pending_givens.each do |entry|
            resolved = resolve_pending_chapter_given(entry)
            entry[:placeholder].description = resolved.description
            entry[:placeholder].canonical   = resolved.canonical
            entry[:placeholder].predicate   = resolved.predicate
          end
          @chapter_pending_givens.clear
        end

        def resolve_pending_chapter_given(entry)
          description = entry[:description]
          candidates  = RuleReference.resolve_owner_keyed(@chapter_named_givens, description)

          if entry[:declared_by]
            candidates[entry[:declared_by]] ||
              raise(Malformed,
                    "#{entry[:aggregate]}'s given #{description.inspect} names no precondition " \
                    "#{entry[:declared_by]} declares in this chapter — #{entry[:declared_by]} " \
                    "either hasn't declared #{description.inspect}, or declared_by: named the " \
                    "wrong aggregate")
          elsif candidates.size == 1
            candidates.values.first
          elsif candidates.empty?
            raise(Malformed,
                  "#{entry[:aggregate]}'s given #{description.inspect} names no precondition " \
                  "any aggregate in this chapter ever declares — declare it once with a block " \
                  "(some aggregate's own given(#{description.inspect}) { ... })")
          else
            raise(Malformed,
                  "#{entry[:aggregate]}'s given #{description.inspect} is ambiguous in this " \
                  "chapter — #{candidates.keys.join(', ')} each declare a DIFFERENT predicate " \
                  "under this same description; name which one with declared_by: (e.g. " \
                  "given(#{description.inspect}, declared_by: #{candidates.keys.first}))")
          end
        end
        private :resolve_pending_chapter_given

        # THE ENTITY-SCOPED ANALOGUE, one level down — see
        # `#resolve_pending_chapter_givens!`'s own comment; identical
        # shape, resolved against `@chapter_entity_named_givens` instead.
        def resolve_pending_chapter_entity_givens!
          @chapter_entity_pending_givens.each do |entry|
            resolved = resolve_pending_chapter_entity_given(entry)
            entry[:placeholder].description = resolved.description
            entry[:placeholder].canonical   = resolved.canonical
            entry[:placeholder].predicate   = resolved.predicate
          end
          @chapter_entity_pending_givens.clear
        end

        def resolve_pending_chapter_entity_given(entry)
          description = entry[:description]
          candidates  = RuleReference.resolve_owner_keyed(@chapter_entity_named_givens, description)

          if entry[:declared_by]
            candidates[entry[:declared_by]] ||
              raise(Malformed,
                    "#{entry[:entity]}'s given #{description.inspect} names no precondition " \
                    "#{entry[:declared_by]} declares in this chapter — #{entry[:declared_by]} " \
                    "either hasn't declared #{description.inspect}, or declared_by: named the " \
                    "wrong piece")
          elsif candidates.size == 1
            candidates.values.first
          elsif candidates.empty?
            raise(Malformed,
                  "#{entry[:entity]}'s given #{description.inspect} names no precondition " \
                  "any piece in this chapter ever declares — declare it once with a block " \
                  "(some piece's own given(#{description.inspect}) { ... })")
          else
            raise(Malformed,
                  "#{entry[:entity]}'s given #{description.inspect} is ambiguous across the " \
                  "chapter's own pieces — #{candidates.keys.join(', ')} each declare a DIFFERENT " \
                  "predicate under this same description; name which one with declared_by: (e.g. " \
                  "given(#{description.inspect}, declared_by: #{candidates.keys.first.inspect}))")
          end
        end
        private :resolve_pending_chapter_entity_given

        # A CHAPTER MAY BE DECLARED IN SEVERAL FILES, meant to merge into ONE
        # domain — `lib/hecks/language/bluebook/*.bluebook` all open
        # `Hecks.bluebook "Bluebook" do ... end`. Each `Hecks.bluebook` call used to
        # mint a fresh builder, so a second file with the same chapter name
        # silently replaced the first's aggregates instead of adding to them.
        #
        # The registry now holds the builder OPEN across calls : the first file
        # for a name creates it, every later file for the same name reuses the
        # same instance, so `@aggregates`/`@read_models` accumulate. `#build` is
        # safe to call once per file on the same builder — it constructs a fresh
        # `Bluebook` from whatever is currently held and re-`Namespace.install`s
        # over the previous one, so the LAST file's call leaves every aggregate
        # seen so far reachable, and each call's IR is a strict superset of the
        # one before. `Registry#add_bluebook` still simply stores by name — with
        # this in place, "last write wins" is the cumulative, correct write.
        def self.build(name, version: nil, &block)
          registry = Hecks.current_registry
          builder  = registry ? registry.bluebook_builder(name) { new(name, version: version) } : new(name, version: version)
          builder.__send__(:adopt_version, version)
          # A bare constant in a bluebook — `attribute :name, PizzaName` — is a NAME,
          # not a reference to something Ruby has heard of. `const_missing` hands
          # over a `ConstShim::ScopedConstant` (S0b, const_shim.rb's own comment),
          # and that is still the whole answer for a bare name: `Attribute` spells
          # it with `to_s`, so the `TypeName` wrapper this used to build existed
          # only long enough to be stringified. The concept still has a home — the
          # language declares `value_object "TypeName"` — it just needed no Ruby
          # class of its own. A Module rather than a Symbol is what also lets
          # `Account::Debit`/`admits: Account::LedgerDirection` answer their OWN
          # `::` — a plain Symbol cannot.
          resolver = ->(const) { ConstShim::ScopedConstant.for(const) }
          ConstShim.with(resolver) { builder.instance_eval(&block) } if block
          builder.build
        end
      end
    end
  end
end
