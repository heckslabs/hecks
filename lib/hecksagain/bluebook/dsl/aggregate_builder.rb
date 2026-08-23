require_relative "word_gate"
module Hecksagain
  module Bluebook
    module DSL
      class AggregateBuilder
        GRAMMAR_CONTEXT = "Aggregate"

        include AttributeCollector
        include IdentityDeclaration
        include RuleReference
        include WordGate

        def initialize(name, chapter_named_givens: {})
          @name          = name
          @value_objects = []
          @commands      = []
          @invariants    = []
          @named_givens  = {}
          @projected_fields = []
          @identity_paths = []
          @entities      = []
          @queries       = []
          @policies      = []
          @reference_targets = []
          # THE ROOT of the cross-entity given pool — see `#entity`'s own
          # comment. ONE hash for the whole aggregate, threaded unchanged
          # into every piece nested under it, however deep.
          @entity_named_givens = {}
          # ONE LEVEL WIDER STILL — the CHAPTER's own pool, threaded in
          # from `BluebookBuilder#aggregate`, shared with every OTHER
          # aggregate the same chapter builds. See `#given`'s own
          # comment for what this closes.
          @chapter_named_givens = chapter_named_givens
          # DEFERRED CONSTRUCTION — `entity`/`command`/`query` push a
          # pending descriptor here instead of building immediately; see
          # `#drain_pending!`'s own comment for why.
          @pending_entities = []
          @pending_commands = []
          @pending_queries  = []
        end

        def description(value)
          # moved to the language: Description invariant, on Root.Declare

          @description = value
        end

        # ORIGIN, not runtime identity — a concept adopted from a canonical
        # source (§28) names where it came from without that fact ever
        # touching `hecks_fqn`/dispatch. Captured raw, the same way
        # `attribute ..., default: { value: "small" }` captures a literal
        # Hash untouched — no re-parsing, no structure imposed beyond
        # "whatever the author wrote."
        # RENAMED FROM `provenance`/`projects`/`lifecycle`/`entity`/
        # `query`/`policy`/`command` (all below) — item #13's full
        # metaprogrammed dispatch (slice 4c). All bootstrap-reachable
        # (used throughout the core/attached chapters), all in
        # GenericDispatch::BOOTSTRAP_CALLS_FALLBACK.
        def provenance_impl(from:)
          @provenance = from
        end

        # `optional:` — matching `CommandBuilder#reference_to`'s own
        # signature, which already had it; this one never forwarded it
        # to `attribute_impl()` even though `attribute_impl()` itself
        # already accepts it. A real gap: an aggregate that can point at
        # ONE OF several targets (Item's own `personal_list_id`/
        # `camping_list_id`, never both) needs each reference optional
        # on the aggregate's own persisted schema, not just as a
        # command's input.
        # RENAMED FROM `reference_to` — item #13's full metaprogrammed
        # dispatch (slice 4b). Bootstrap-reachable (every core/attached
        # grammar chapter uses reference_to to describe itself), so also
        # named in GenericDispatch::BOOTSTRAP_CALLS_FALLBACK.
        def reference_to_impl(type, as: nil, optional: false)
          target = Naming.demodulise(type)
          @reference_targets << target
          relationship_attribute(target, :reference_to,
                                 as || default_reference_name(target), optional: optional)
        end

        # A RULE MAY ONLY READ WITHIN ITS OWN AGGREGATE BOUNDARY (S12,
        # ADR 0025 — "Consistency across aggregate boundaries"). A
        # `given`/`ensures`/`invariant` used to reach through a
        # `reference_to` at RULE-EVALUATION TIME (`References#
        # dereference`, a live query against another aggregate's own
        # repository, unbounded and inconsistent with the "a rule reads
        # only this record" model everywhere else) — `projects` is what
        # replaces that: `projects :customer_status, from: :"customer.
        # status"` declares that THIS aggregate holds its own copy of
        # `Customer`'s own `:status`, kept fresh by a REBUILD SWEEP
        # (`Runtime::ProjectionRebuild`) rather than read live. A rule
        # then reads `customer_status` the same way it reads any other
        # local field — no dot, no reference walk.
        #
        # `from:` NAMES THE LOCAL REFERENCE, not the target aggregate —
        # `customer`, the attribute THIS aggregate's own `reference_to
        # Customer` already minted, not `Customer` the type — so two
        # references to the same aggregate (aliased differently) can
        # each carry their own projection without ambiguity. The TARGET
        # field's own existence cannot be checked here: the target
        # aggregate does not exist yet while THIS one is still being
        # declared (the same reason a query's own hop tail is checked
        # by `BluebookBuilder#validate_query_hops!`, once every
        # aggregate in the chapter is real, not by `AggregateBuilder`
        # itself) — `validate_projected_fields!` is where that half
        # happens.
        def projects_impl(name, from:)
          reference, _, remote_field = from.to_s.rpartition(".")

          if reference.empty? || remote_field.empty?
            raise Malformed,
                  "#{@name}.projects :#{name} names #{from.inspect}, which is not " \
                  "reference.field — say which reference and which field on it, e.g. " \
                  "from: :\"customer.status\""
          end

          @projected_fields << ProjectedField.new(name: name.to_sym, reference: reference.to_sym,
                                                  remote_field: remote_field.to_sym)
        end

        # `has_many`/`has_one`/`belongs_to` were LEGACY (ADR 0025,
        # "References") — sugar over `reference_to` that collapsed to an
        # anonymous reference and, for `has_many`, LIED (singularised its
        # target and minted one scalar, so `film.backers` read `nil` and
        # never `[]`). Wave 6 (identity-and-relationships arc) un-deprecates
        # all three for real: a relationship word now retains the author's
        # domain concept in IR — still stored as one or more target
        # identities, but no longer collapsed to a bare `reference_to`
        # during assembly. `MetaValidator.shadow_parsing?` still routes to
        # `legacy_has_many`/`legacy_has_one` so frozen era text written
        # under the OLD (lying/collapsing) meaning still parses the way it
        # did when it was written — real, if rare corpus: "Combined corpus
        # uses: one."
        #
        # RENAMED FROM `has_many`/`has_one`/`belongs_to` — item #13's full
        # metaprogrammed dispatch (slice 4). Each Keyword row's own
        # `calls:` names the matching `_impl`; not bootstrap-reachable
        # (no core/attached chapter uses one of these to describe itself),
        # so no BOOTSTRAP_CALLS_FALLBACK entry is needed, unlike
        # `attribute`/`role`.
        def has_many_impl(type, as: nil, **legacy_options)
          if MetaValidator.shadow_parsing?
            return legacy_has_many(type, as: as, optional: legacy_options.fetch(:optional, false))
          end

          unless legacy_options.empty?
            raise Malformed, "#{@name}.has_many takes no #{legacy_options.keys.first}: — an empty list already means none"
          end

          plural = Naming.demodulise(type)
          target = Naming.singularize(plural)
          @reference_targets << target
          relationship_attribute(target, :has_many, as || Naming.snake(plural).to_sym,
                                 list: true)
        end

        def has_one_impl(type, as: nil, optional: false)
          return legacy_has_one(type, as: as, optional: optional) if MetaValidator.shadow_parsing?

          target = Naming.demodulise(type)
          @reference_targets << target
          relationship_attribute(target, :has_one, as || Naming.snake(target).to_sym,
                                 optional: optional)
        end

        def belongs_to_impl(type, as: nil, optional: false)
          return legacy_has_one(type, as: as, optional: optional) if MetaValidator.shadow_parsing?

          target = Naming.demodulise(type)
          @reference_targets << target
          relationship_attribute(target, :belongs_to, as || Naming.snake(target).to_sym,
                                 optional: optional)
        end

        def lifecycle_impl(field, default:, &block)
          @lifecycle = LifecycleBuilder.build(field, default: default, &block)
        end

        # A piece is declared IN this aggregate — its owner is stamped by
        # `Aggregate#initialize`, once the aggregate exists. Its own
        # commands were given the piece as their owner when it was declared,
        # so the chain closes as chapter -> aggregate -> entity -> command.
        # NOT built here — see `#drain_pending!`'s own comment for why
        # this only queues a descriptor.
        #
        # A PRECONDITION SHARED ACROSS SIBLING PIECES, DECLARED ONCE — one
        # level wider than round 4's own `EntityBuilder#given` (shared
        # across ONE piece's own commands): `@entity_named_givens` is the
        # SAME hash threaded into EVERY piece this aggregate builds, so a
        # piece's own entity-level `given(desc) { block }` write-throughs
        # into it, and any OTHER piece's own command can reference it back
        # bare, the identical description/canonical, evaluated in ITS OWN
        # `parent`-relative context. Real, live corpus this closes:
        # `SafeDepositBox`'s `Visit`/`KeyIssuance` — two DIFFERENT pieces
        # under one head, each independently typing `given("customer is
        # active") { parent.customer.status == "active" }` byte for byte,
        # which neither the aggregate's OWN "customer is active" (a
        # DIFFERENT canonical — bare `customer.status`, not
        # `parent.customer.status`, wrong scope for a piece's own command
        # to evaluate) nor round 4's single-piece `given` could reach.
        def entity_impl(name, &block)
          @pending_entities << [name, block]
        end

        def query_impl(name, &block)
          @pending_queries << [name, block]
        end

        def policy_impl(name, &block)
          reaction = PolicyBuilder.build(name, &block)
          reaction.aggregate = @name
          @policies << reaction
        end

        # `builder.closed_sets` TOO, not only `builder.build` — a REAL,
        # previously-unreachable gap this exact fix exposed: a
        # value_object's own INLINE `attribute :x, one_of(...)` (now legal
        # — S3, ADR 0025 removed the wrong-arity collision that used to
        # make this crash before it could ever matter) synthesises its own
        # anonymous value object via the SAME `AttributeCollector#closed_
        # sets` mechanism an aggregate's own attributes already use — and
        # nothing installed it anywhere. `Box.attributes` said `size:
        # "Size"` while no "Size" value object existed in the whole
        # domain: a dangling type name, not a working closed set. Flattened
        # into THIS aggregate's own `@value_objects`, the identical move
        # `@value_objects + closed_sets` already makes for the aggregate's
        # own direct attributes (see this file's other 5 call sites).
        def value_object(name, &block)
          builder = ValueObjectBuilder.new(name, owner_value_objects: @value_objects + closed_sets)
          builder.instance_eval(&block) if block
          @value_objects << builder.build
          @value_objects.concat(builder.closed_sets)
        end

        # `from:` — LIFECYCLE STATE BECOMES A COMMAND GUARD (S10, ADR
        # 0025) — `command "Debit", from: "open"` replaces `given
        # ("account is open") { status == "open" }`, written 35 times
        # in two wordings across the corpus. Checked against THIS
        # aggregate's own lifecycle field (`Admissibility#enforce_
        # lifecycle_guard`) — never a target state, never a transition:
        # the lifecycle already declares which states exist, so naming
        # the legal ones is checkable against it, where a free-text
        # given could drift out of sync with the state machine and did.
        def command_impl(name, from: nil, &block)
          # The verb is declared ON this aggregate — the owner `acts_on` answers
          # with — stamped by `Aggregate#initialize` once the aggregate
          # exists. An ENTITY's commands take the entity as their owner instead,
          # at the entity's own declaration. NOT built here — see
          # `#drain_pending!`'s own comment for why this only queues a
          # descriptor.
          @pending_commands << [name, from, block]
        end

        # A PRECONDITION SHARED ACROSS COMMANDS, DECLARED ONCE (S10, ADR
        # 0025) — an aggregate-level `given`, block required, stored by
        # its own description rather than appended anywhere: a command
        # names it back (`given("customer is active")`, no block of its
        # own) rather than re-typing the predicate, so there is one
        # description and therefore one refusal message no matter which
        # command a caller hits. DECLARE BEFORE THE COMMANDS THAT
        # REFERENCE IT — resolution happens at the referencing command's
        # OWN build time (`CommandBuilder#given`), against whatever this
        # aggregate has declared SO FAR, the one ordering constraint this
        # word carries that `identified_by`/`attribute` do not.
        # BARE — NO BLOCK — REFERENCES a SIBLING AGGREGATE's own
        # already-declared precondition, one level wider than the
        # existing bare-command-references-its-own-aggregate shape
        # (`CommandBuilder#reference_named_given`): `SafeDepositBox`/
        # `OnboardingCase` both name back `Account`'s own "customer is
        # active" rather than retyping `customer.status == "active"` a
        # third and fourth time. Resolved against `@chapter_named_givens`
        # — see `BluebookBuilder#aggregate`'s own comment for how that
        # pool is threaded, and `docs/implemented/resolution-rules/chapter-given.md`
        # for the full algorithm and its known limitations (a bare
        # reference trusts its own author to have verified the SAME
        # canonical predicate applies — this mechanism does not, and
        # cannot, check that itself; see that doc for which real corpus
        # cases do and do not qualify).
        #
        # `declared_by:` DISAMBIGUATES the same description meaning TWO
        # genuinely different predicates chapter-wide — real, live:
        # `Account`'s own "customer is active" reads bare
        # `customer.status` (a DIRECT `reference_to Customer`); `ATMCard`'s
        # own (shared onward with `CardPayment`/`ExternalTransfer`/
        # `ScheduledPayment`/`Statement`) reads `account.customer.status`
        # (reached THROUGH `Account`) — the identical business fact, a
        # genuinely different runtime path, correctly kept as the SAME
        # domain wording rather than invented a second spelling for "the
        # same idea, one more hop away" (S10, ADR 0025's own "one idea,
        # one spelling"). Omit it when the description is unambiguous
        # chapter-wide (the common case, and the ONLY case this took
        # before this parameter existed) — required only once a SECOND,
        # textually-different canonical registers under the same
        # description; see `reference_named_chapter_given`'s own
        # ambiguity error for how that surfaces.
        # RENAMED FROM `given` — item #13's full metaprogrammed dispatch
        # (slice 4b), same reasoning as reference_to_impl above:
        # bootstrap-reachable, in BOOTSTRAP_CALLS_FALLBACK.
        def given_impl(description, declared_by: nil, &predicate)
          return reference_named_chapter_given(description, declared_by: declared_by) unless predicate

          named = build_rule(Given, description, predicate, owner_name: @name, word: "given",
                              extraction_failure: "its source could not be read, so no other runtime could ever evaluate it")
          @named_givens[description] = named
          # WRITE-THROUGH, first-declared-wins PER OWNER — keyed by
          # [description, this aggregate's own name], not description
          # alone: two DIFFERENT aggregates independently declaring the
          # SAME description are two DISTINCT candidates a later bare
          # reference chooses between (via `declared_by:` once there is
          # more than one), never silently merged into one slot the way
          # a bare description-only key would.
          @chapter_named_givens[description] ||= {}
          @chapter_named_givens[description][@name] ||= named
        end

        private

        # PRIMITIVE 2 (RuleReference#resolve_owner_keyed) — see that
        # method's own comment for the pool shape; the four branches
        # below (exact owner / unambiguous single candidate / none /
        # ambiguous) are this construct's OWN refusal wording, not
        # shared, since `declared_by:` only exists here so far.
        def reference_named_chapter_given(description, declared_by:)
          verify_resolves_via!("given", "Aggregate", "owner_keyed")
          candidates = resolve_owner_keyed(@chapter_named_givens, description)

          named =
            if declared_by
              owner = Naming.demodulise(declared_by)
              candidates[owner] ||
                raise(Malformed,
                      "#{@name}'s given #{description.inspect} names no precondition " \
                      "#{owner} declares in this chapter — #{owner} either hasn't declared " \
                      "#{description.inspect}, or declared_by: named the wrong aggregate")
            elsif candidates.size == 1
              candidates.values.first
            elsif candidates.empty?
              raise(Malformed,
                    "#{@name}'s given #{description.inspect} names no precondition " \
                    "any aggregate in this chapter has declared yet — declare it once " \
                    "with a block (some aggregate's own given(#{description.inspect}) " \
                    "{ ... }), before the aggregates that reference it")
            else
              raise(Malformed,
                    "#{@name}'s given #{description.inspect} is ambiguous in this chapter — " \
                    "#{candidates.keys.join(', ')} each declare a DIFFERENT predicate under " \
                    "this same description; name which one with declared_by: (e.g. " \
                    "given(#{description.inspect}, declared_by: #{candidates.keys.first}))")
            end

          @named_givens[description] = named
        end

        public

        # THE AGGREGATE BOUNDARY IS WHAT AN INVARIANT DEFINES (S10, ADR
        # 0025 — "Rules") — checked after every command, before save,
        # the same way a value object's already is
        # (`ValueObjectBuilder#invariant`, whose own shape this mirrors
        # exactly). Today `invariant` lived only inside `value_object`;
        # an aggregate-level rule had nowhere to live, so "the balance
        # never goes negative" was three different `given`/`ensures`
        # texts across banking's six balance-moving commands, and the
        # four that only increase it said nothing at all — completeness
        # depended on someone noticing which commands could decrease it.
        # RENAMED FROM `invariant` — item #13's full metaprogrammed
        # dispatch (slice 4b), same reasoning as given_impl above.
        def invariant_impl(description, &predicate)
          @invariants << build_rule(Invariant, description, predicate, owner_name: @name, word: "invariant",
                                     extraction_failure: "it would be a rule the IR cannot carry")
        end

        def build
          drain_pending!
          resolve_pending_identity!
          seal_mutation_targets
          seal_query_targets
          seal_defaults
          seal_lifecycle_guards
          seal_projected_fields

          ir = Aggregate.new(
            name:              @name,
            description:       @description,
            attributes:        attributes,
            value_objects:     @value_objects + closed_sets,
            commands:          @commands,
            invariants:        @invariants,
            preconditions:     @named_givens.values,
            projected_fields:  @projected_fields,
            identified_by:     @identity_paths,
            lifecycle:         @lifecycle,
            entities:          @entities,
            queries:           @queries,
            policies:          @policies,
            reference_targets: @reference_targets + entity_reference_targets,
            provenance:        @provenance
          )

          # After the IR exists, on purpose : a reference is declared IN the
          # aggregate, and the aggregate the IR graph knows is `ir`, not the
          # builder.
          stamp_references(ir)
          ir
        end

        def self.build(name, chapter_named_givens: {}, &block)
          builder = new(name, chapter_named_givens: chapter_named_givens)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

        # DEFERRED CONSTRUCTION — `entity`/`command`/`query` used to build
        # immediately, INLINE, the moment their own DSL line ran during
        # `instance_eval` — meaning a command's own resolution (`sets
        # :field` importing the owner's own attribute, `given("desc")`
        # referencing an aggregate-level precondition, a query's own
        # positional-param resolution) only ever saw whatever `@entities`/
        # `attributes`/`@named_givens`/`@value_objects` held AS OF THAT
        # EXACT TEXTUAL LINE — never what the aggregate's block would go
        # on to declare after it. Three real, confirmed cases in the
        # self-hosted meta-domain violate the "declare before you
        # reference" convention every other resolution rule relies on
        # (`command "Handler"` before `entity "Handler"`, same for
        # Member/Dispatch — see docs/resolution-rules/
        # implicit-append-fields.md's own "Known limitations").
        #
        # This is the SAME move `BluebookBuilder` already makes one level
        # UP, at the CHAPTER level — build every aggregate first, THEN run
        # cross-referential validation (`validate_query_hops!`,
        # `validate_projected_fields!`, `validate_no_bidirectional_
        # references!`) once `@aggregates` is fully populated — extended
        # one level down: `entity`/`command`/`query` now only QUEUE a
        # descriptor (`@pending_entities`/`@pending_commands`/
        # `@pending_queries`, each preserving its own declared order),
        # and `#build` drains them here, in this exact order, BEFORE any
        # of the existing `seal_*` validations (which already assume
        # `@commands`/`@entities`/`@queries` are the real, final, built
        # objects) — entities FIRST and fully, since a command's own
        # `sets :list, append: {...}` needs a list's element entity
        # already built (`.attributes` populated) to resolve against, not
        # just named.
        #
        # `attribute`/`value_object`/`identified_by`/`given` (block form)
        # are NOT deferred — they still build eagerly during
        # `instance_eval`, unchanged. Nothing reads `@entities`/
        # `@commands`/`@queries` from anywhere OTHER than `#build` and its
        # own private helpers (checked directly), so nothing else in this
        # file needed to change for this to be safe.
        def drain_pending!
          @entities = @pending_entities.map do |name, block|
            EntityBuilder.build(name, owner_value_objects:             @value_objects + closed_sets,
                                      owner_named_givens:              @entity_named_givens,
                                      identity_name_prefix:            "#{Naming.demodulise(@name)}#{Naming.demodulise(name)}",
                                      identity_value_object_installer: ->(value_object) { @value_objects << value_object },
                                &block)
          end

          @commands = @pending_commands.map do |name, from, block|
            CommandBuilder.build(name, owner: @name, from: from, named_givens: @named_givens,
                                        owner_attributes: attributes,
                                        owner_constructs: @value_objects + closed_sets + @entities, &block)
          end

          @queries = @pending_queries.map do |name, block|
            QueryBuilder.build(name, owner_attributes: attributes, &block)
          end
        end

        # `identified_by`'s own resolution pool (AttributeCollector#resolve_
        # pending_identity!'s hook, S9) — an aggregate resolves a bare
        # field's own value-object type against everything it declares
        # itself, own inline closed sets included.
        def identity_pool = @value_objects + closed_sets

        def identity_value_object_name = "#{Naming.demodulise(@name)}Identity"

        def install_identity_value_object!(value_object)
          @value_objects << value_object
        end

        # LEGACY — see `has_many`/`has_one`/`belongs_to`'s own comment;
        # byte-identical to what those three did before this slice.
        def legacy_has_many(type, as:, optional: false)
          plural = Naming.demodulise(type)
          reference_to_impl(Naming.singularize(plural), as: as || Naming.snake(plural).to_sym, optional: optional)
        end

        def legacy_has_one(type, as:, optional: false)
          reference_to_impl(type, as: as || Naming.snake(Naming.demodulise(type)).to_sym, optional: optional)
        end

        # Every reference is told which Aggregate declares it, so it can
        # find the chapter and resolve its target.
        #
        # Stamped HERE, at build, rather than at `reference_to`, because a command
        # builder does not hold the aggregate and should not learn to. And
        # deliberately across every list that can carry one — a reference the walk
        # missed would resolve to nil, and `resolve_references` SKIPS a nil target,
        # so the guarantee would go quiet instead of going red. That is the exact
        # shape of the bug that let an Account belong to an unregistered customer
        # fourteen times over.
        def stamp_references(ir)
          reference_bearing_attributes.each { |attribute| attribute.type.declared_in = ir }
        end

        # AN OWNED PIECE'S OWN `reference_to` IS AN EDGE THIS AGGREGATE
        # POINTS ACROSS TOO (S9, ADR 0025 — "entity/aggregate shared
        # vocabulary") — a ring closing through a contained piece (Board
        # -> Board::Card -> Product -> Board) is the same "no boundary
        # anyone can reason about alone" `validate_no_bidirectional_
        # references!` already refuses for a direct aggregate-to-
        # aggregate ring; it was invisible before this because only
        # `AggregateBuilder#reference_to` ever fed `@reference_targets`,
        # never `EntityBuilder#reference_to`. Command/query reference
        # ARGUMENTS are deliberately excluded — they are data flowing
        # through a dispatch, not persisted state the graph a cycle
        # means anything over.
        def entity_reference_targets
          @entities.flat_map { |entity| entity.attributes.select(&:reference?).map { |a| a.type.target_name.to_s } }
        end

        def reference_bearing_attributes
          lists = [attributes, *@commands.map(&:attributes), *@queries.map(&:attributes)]
          @entities.each do |entity|
            lists << entity.attributes
            lists.concat(entity.commands.map(&:attributes))
            lists.concat(entity.queries.map(&:attributes))
          end

          lists.flatten.select(&:reference?)
        end

        # A mutation must name a field the aggregate actually HAS.
        #
        # NOT moved to the language, and deliberately so. The language says only
        # `given("a mutation names a target") { !target.value.to_s.empty? }` —
        # non-emptiness — because saying more means reaching a list that lives on
        # a DIFFERENT root : a command's changes hang off Command, the fields they
        # name hang off Aggregate, and a given is a closed predicate over its own
        # state. Aggregate.Seal is the right shape and cannot see commands ; the
        # reference trick that rescued "attributes use value-object types" needs a
        # root to point at, and an aggregate's fields are a value-object list, not
        # roots. This is the second rule that cannot port for that reason — the
        # first is read-model uniqueness — and both wait on the same thing : a
        # quantifier, or fields promoted to roots.
        #
        # So it lives here, at build, where every declaration is present. Found by
        # writing `then_set :disputed_by` on CardPayment before the field existed :
        # it wrote into nothing, refused nothing, and every check stayed green.
        # A DEFAULT FILLS THE SHAPE IT IS DECLARED ON, or it fills nothing.
        #
        # `attribute :cover, one_of("covered", "open"), default: "open"` builds
        # cleanly and then refuses EVERY create at dispatch — "cover is a Cover,
        # pass its fields as an object" — because the value object wants its
        # fields and got a bare string. The bluebook is wrong at the line where
        # it is written and says so nowhere near it.
        #
        # It cost a corpus member 33 refusals out of 40 steps, with every gate
        # green throughout: the refusals were perfectly consistent, which is
        # consistency about nothing. `till.bluebook` has always had the right shape
        # — `default: { cents: 0 }`.
        #
        # A PRIMITIVE takes a scalar and a VALUE OBJECT takes its fields, so the
        # test is simply which one the type names. Nothing here guesses at the
        # keys: a default that is a Hash is left to `Value.for_attribute`, which
        # is where a wrong FIELD belongs.
        def seal_defaults
          shapes = @value_objects.map { |shape| shape.hecks_name.to_s }

          attributes.each do |attribute|
            next if attribute.default.nil? || attribute.default.is_a?(Hash)
            next unless shapes.include?(attribute.type.to_s)

            raise Malformed,
                  "#{@name}.#{attribute.name} defaults to #{attribute.default.inspect}, but " \
                  "#{attribute.type} is a value object — a default fills its FIELDS " \
                  "(default: { ... }), and a bare value refuses every create instead"
          end
        end

        # A command's `from:` guard needs a lifecycle field to check
        # against — declared at BUILD time (S10, ADR 0025), the same
        # point every other "does this actually resolve" check in this
        # file runs, rather than left to crash `enforce_lifecycle_
        # guard` the first time such a command is ever dispatched.
        def seal_lifecycle_guards
          return if @lifecycle

          @commands.each do |command|
            next unless command.from

            raise Malformed,
                  "#{@name}.#{command.hecks_name} guards from: #{Array(command.from).inspect}, but " \
                  "#{@name} declares no lifecycle — from: checks a lifecycle field, and there is " \
                  "none here to check"
          end
        end

        # `projects`'s OWN half of "does this actually resolve" (S12,
        # ADR 0025) — the LOCAL half only: `reference` must name a real
        # reference-typed attribute this aggregate declares, and
        # `name` must not collide with an attribute already declared
        # (a projected field is its own kind of field, never a second
        # spelling of one that already exists). The TARGET aggregate's
        # own field is checked separately, once every aggregate in the
        # chapter is real — see BluebookBuilder#validate_projected_
        # fields!'s own comment for why that half cannot happen here.
        def seal_projected_fields
          declared = attributes.map { |attribute| attribute.name.to_sym }

          @projected_fields.each do |field|
            if declared.include?(field.name)
              raise Malformed,
                    "#{@name}.projects :#{field.name} names a field #{@name} already declares — " \
                    "a projected field is never a second spelling of one that already exists"
            end

            reference_attribute = attributes.find { |attribute| attribute.name == field.reference }
            unless reference_attribute&.reference?
              raise Malformed,
                    "#{@name}.projects :#{field.name} reads through #{field.reference.inspect}, which " \
                    "#{@name} never declares as a reference_to — projects reads through a REFERENCE, " \
                    "never a value object or a scalar"
            end
          end
        end

        def seal_mutation_targets
          known = attributes.map { |attribute| attribute.name.to_sym }
          known << @lifecycle.field.to_sym if @lifecycle

          @commands.each do |command|
            command.mutations.each do |mutation|
              # `:delegate` — CommandBuilder#delegates_to's own comment —
              # targets no field of THIS aggregate at all; its `target`
              # names an "Entity.Command" pair instead, checked when the
              # command builds (`delegates_to`'s own `rpartition` guard)
              # and again at dispatch time (`CommandInterpreter
              # #step_delegate_to_entity`, which refuses a real one that
              # names no such entity or command). Sealing THIS check
              # against it would refuse every delegating command outright.
              next if mutation.op == :delegate
              next if known.include?(mutation.target.to_sym)

              raise Malformed,
                    "#{@name}.#{command.hecks_name} sets #{mutation.target}, which #{@name} " \
                    "never declares — a mutation into a field that does not exist " \
                    "writes nothing and refuses nothing"
            end
          end
        end

        # A query must ask about a field the aggregate actually HAS — the same
        # seal `then_set` gets, closing the same silence: a where over a field
        # nothing declares matches nothing and refuses nothing, forever, on
        # every adapter. Three more silences close with it. A dotted path may
        # reach through the value-object graph but must LAND on a scalar
        # member (QuerySpecification::FieldPath is the one walk every engine
        # now shares) — landing on a value object hands SQL a JSON object
        # where the reference interpreter unwraps a hash. An ordered
        # comparator (lt/gt/gte/lte) must land on a numeric leaf — over text
        # the reference interpreter quietly matches no rows while SQL
        # compares lexicographically. And a :symbol value must name one of
        # the query's own declared arguments, or it resolves to nil at
        # dispatch and matches nothing.
        ORDERED_COMPARATORS = %i[lt lte gt gte].freeze

        def seal_query_targets
          query_surfaces.each do |owner, fields, lifecycle, queries|
            queries.each do |query|
              query.wheres.each do |clause|
                seal_query_field(owner, query, fields, lifecycle, clause.field)
                seal_ordered_comparator(owner, query, fields, clause)
                infer_local_query_argument(query, fields, lifecycle, clause)
                seal_query_argument(owner, query, clause.value) unless clause.field.to_s.include?("/")
              end
              seal_query_field(owner, query, fields, lifecycle, query.order_by.field, ordering: true) if query.order_by
              seal_query_argument(owner, query, query.limit&.value)
              seal_query_argument(owner, query, query.offset&.value)
            end
          end
        end

        def query_surfaces
          [[@name, attributes, @lifecycle, @queries]] +
            @entities.map { |entity| ["#{@name}::#{entity.hecks_name}", entity.attributes, entity.lifecycle, entity.queries] }
        end

        # `/` CROSSES INTO ANOTHER RECORD, `.` WALKS FIELDS INSIDE THIS
        # ONE (ADR 0025, "References") — the operator answers which
        # kind of path this is now, not a name collision to arbitrate,
        # so a hop is routed to its own method before any `.`-splitting
        # runs at all; `seal_query_hop` below never sees a field this
        # one would also have tried to resolve as a local dotted walk.
        def seal_query_field(owner, query, fields, lifecycle, field, ordering: false)
          return seal_query_hop(owner, query, fields, field, ordering: ordering) if field.to_s.include?("/")

          name, *nested = field.to_s.split(".")
          attribute = fields.find { |candidate| candidate.name.to_s == name }
          if nested.empty? && attribute
            refuse_ambiguous_comparison!(owner, query, field, attribute)
            return
          end
          return if nested.empty? && lifecycle&.field.to_s == name
          return if nested.any? && attribute && scalar_path?(attribute, nested)

          if nested.any? && attribute && resolves?(attribute, nested)
            raise Malformed,
                  "#{owner}.#{query.hecks_name} asks about #{field}, which lands on a " \
                  "value object, not a scalar — a dotted query path ends on a scalar " \
                  "member, or the engines answer it differently"
          end

          raise Malformed,
                "#{owner}.#{query.hecks_name} asks about #{field}, which #{owner} " \
                "never declares — a query over a field that does not exist " \
                "matches nothing and refuses nothing"
        end

        # ORDER BY refuses a hop OUTRIGHT, right here — unlike a WHERE
        # hop (deferred below), this doesn't need the target's shape to
        # answer: an ask is ordered by what its own answering rows
        # hold, and a hop answers with a candidate set, not a sort key
        # (see Runtime::ReferenceHop).
        #
        # A WHERE hop is only RECOGNISED here, and CHECKED LATER. The
        # head names one of this aggregate's own references, which is
        # answerable now — a Reference knows its own target_name at
        # declaration. What it points AT is not: stamp_references has
        # already run by this point, but the chapter (Bluebook, and the
        # owning aggregate's OWN place in it) does not exist yet, so
        # Reference#resolve would answer nil for every target in the
        # file, including ones declared above this one. The tail, and
        # whether the target even exists, are BluebookBuilder's
        # business — see validate_query_hops!, which runs once the
        # chapter is real, for exactly the reason
        # validate_no_bidirectional_references! already gives for
        # living at that same later point.
        def seal_query_hop(owner, query, fields, field, ordering:)
          unless QuerySpecification::HopPath.hop_head?(field, fields)
            raise Malformed,
                  "#{owner}.#{query.hecks_name} asks about #{field}, which #{owner} " \
                  "never declares — a query over a field that does not exist " \
                  "matches nothing and refuses nothing"
          end

          return unless ordering

          raise Malformed,
                "#{owner}.#{query.hecks_name} orders by #{field}, which hops through " \
                "a reference — an ask is ordered by what its own answering rows " \
                "hold, and a hop answers with a candidate set, not a sort key"
        end

        def seal_ordered_comparator(owner, query, fields, clause)
          return unless ORDERED_COMPARATORS.include?(clause.op.to_s.to_sym)

          # A WHERE clause hopping through a reference with an ordered
          # comparator is legitimate ("client whose balance > 500") —
          # unlike ORDER BY (refused outright in seal_query_field, see
          # its own comment), a where-clause hop answers a real
          # candidate set either way, ordered or not. Deferred for the
          # same reason any other hop is: whether the tail is even
          # numeric is BluebookBuilder#validate_query_hops!'s question
          # to ask of the TARGET's shape, not this aggregate's own.
          return if clause.field.to_s.include?("/") && QuerySpecification::HopPath.hop_head?(clause.field, fields)

          name, *nested = clause.field.to_s.split(".")
          attribute = fields.find { |candidate| candidate.name.to_s == name }
          return if attribute &&
                    QuerySpecification::FieldPath.numeric?(attribute, nested) { |type| declared_value_object(type) }

          held = attribute ? "holds no number" : "is the lifecycle field, which holds text"
          raise Malformed,
                "#{owner}.#{query.hecks_name} compares #{clause.field} with #{clause.op}, " \
                "but #{clause.field} #{held} — an ordered comparison needs a numeric " \
                "field, and over anything else the adapters answer differently or not at all"
        end

        def seal_query_argument(owner, query, value)
          return unless value.is_a?(Symbol)
          return if query.attribute(value)

          raise Malformed,
                "#{owner}.#{query.hecks_name} resolves :#{value} from its arguments, " \
                "but declares no #{value} attribute — an argument that does not exist " \
                "resolves to nil and matches nothing"
        end

        # A symbolic right-hand side is a query input. When the compared path
        # lands on this owner's declared shape, its type is already known and
        # repeating an `attribute` line inside the query adds no information.
        # Reference hops are resolved only after the whole chapter has been
        # owner-stamped; BluebookBuilder performs the identical inference for
        # those deferred paths.
        def infer_local_query_argument(query, fields, lifecycle, clause)
          name = clause.value
          return unless name.is_a?(Symbol)
          return if query.attribute(name)
          return if clause.field.to_s.include?("/")

          head, *nested = clause.field.to_s.split(".")
          leaf = if nested.empty? && lifecycle&.field.to_s == head
                   Attribute.new(name: name, type: String)
                 else
                   root = fields.find { |candidate| candidate.name.to_s == head }
                   found = root && QuerySpecification::FieldPath.leaf_attribute(root, nested) do |type|
                     declared_value_object(type)
                   end
                   found && Attribute.new(name: name, type: found.type, list: found.list?)
                 end
          query.attributes << leaf if leaf
        end

        # A BARE FIELD NAMING A VALUE OBJECT HAS TO SAY WHICH MEMBER IT
        # MEANS, when more than one could answer. The dotted case above
        # already refuses a path that lands on a value object rather than
        # a scalar; a bare name was returning unconditionally, so
        # `where(frequency: ...)` against a StatementFrequency
        # (cadence, retention_months, paper_fee_cents) compiled — and the
        # engines then disagreed about which member it meant, one taking
        # the FIRST numeric and another declining to unwrap at all.
        #
        # Unambiguous is: exactly one member, whatever its type, or
        # exactly one NUMERIC member among several (Money's `cents`
        # beside its `currency` — the reading every engine already
        # shared, and what the corpus relies on). Anything else names
        # its member with a dotted path, which already works.
        #
        # A list is exempt: `contains` over a `list_of` reads element
        # membership, not a scalar comparison, and has its own agreed
        # reading across the engines.
        def refuse_ambiguous_comparison!(owner, query, field, attribute)
          return if attribute.list?

          value_object = declared_value_object(attribute.type.to_s)
          return unless value_object

          members = QuerySpecification::Common::Comparison.ambiguous_members(value_object)
          return if members.empty?

          raise Malformed,
                "#{owner}.#{query.hecks_name} asks about #{field}, which names #{attribute.type} — " \
                "it has #{members.size} members (#{members.join(', ')}) and no single one a " \
                "comparison can mean; name the member (#{field}.#{members.first})"
        end

        def scalar_path?(attribute, nested)
          QuerySpecification::FieldPath.scalar_leaf?(attribute, nested) { |type| declared_value_object(type) }
        end

        def resolves?(attribute, nested)
          !QuerySpecification::FieldPath.leaf_attribute(attribute, nested) { |type| declared_value_object(type) }.nil?
        end

        def declared_value_object(type_name)
          (@value_objects + closed_sets).find { |shape| shape.hecks_name.to_s == type_name }
        end
      end
    end
  end
end
