require_relative "word_gate"
require_relative "aggregate_builder/sealing"
module Hecks
  module Bluebook
    module DSL
      # The `aggregate "Name" do ... end` receiver — the largest DSL builder
      # in the language, collecting everything an aggregate declares
      # (attributes, value objects, entities, commands, queries, policies,
      # invariants, preconditions, projected fields, its lifecycle and
      # identity) and assembling the final `Aggregate` IR in `#build`.
      # `entity`/`command`/`query` only QUEUE a descriptor during
      # `instance_eval` (`#drain_pending!` builds them, in order, once the
      # whole block has run) so a later-declared piece can still be
      # referenced by an earlier line — see `#drain_pending!`'s own header.
      class AggregateBuilder
        GRAMMAR_CONTEXT = "Aggregate".freeze

        include AttributeCollector
        include IdentityDeclaration
        include RuleReference
        include WordGate
        include Sealing

        def initialize(name, chapter_named_givens: {}, chapter_pending_givens: [],
                       chapter_entity_named_givens: {}, chapter_entity_pending_givens: [])
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
          # A CHAPTER MAY BE SPLIT ACROSS FILES — threaded in the SAME
          # way as `@chapter_named_givens`, one Array shared chapter-wide.
          # See `#pending_chapter_given`'s own comment for what queues
          # here and `BluebookBuilder#resolve_pending_chapter_givens!`
          # for where it drains.
          @chapter_pending_givens = chapter_pending_givens
          # ONE LEVEL WIDER STILL, PAST THE CHAPTER'S OWN AGGREGATE-LEVEL
          # POOL — the chapter's own entity-scoped pool, threaded from
          # `BluebookBuilder#aggregate_impl` the same way
          # `@chapter_named_givens` is, and passed straight through
          # (unchanged) to every top-level piece this aggregate builds
          # (`#drain_pending!`). See `EntityBuilder#given_impl`'s own
          # comment for what this closes.
          @chapter_entity_named_givens   = chapter_entity_named_givens
          @chapter_entity_pending_givens = chapter_entity_pending_givens
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
          return legacy_has_many(type, as: as, optional: legacy_options.fetch(:optional, false)) if MetaValidator.shadow_parsing?

          unless legacy_options.empty?
            raise Malformed,
                  "#{@name}.has_many takes no #{legacy_options.keys.first}: — an empty list already means none"
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

        def lifecycle_impl(field, default:, &)
          @lifecycle = LifecycleBuilder.build(field, default: default, &)
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

        def policy_impl(name, &)
          reaction = PolicyBuilder.build(name, &)
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
        # `type` — THE BARE SHORTHAND (single-attribute value objects):
        # `value_object :Price, Integer` declares a value object with
        # exactly one attribute, NAMED `value`, of that type — pure sugar
        # for `value_object("Price") { attribute :value, Integer }`,
        # routed through the SAME `attribute_impl` the block form's own
        # `attribute` line reaches (so the quoted-text-type refusal,
        # `one_of(...)`/`list_of(...)` synthesis, everything an attribute
        # line already does, applies unchanged rather than being
        # re-derived here). The name `value` is not arbitrary: a
        # single-attribute value object is a NAME for a scalar, not a
        # genuine group ([[feedback_name_the_scalar_field]], `Behaviour::
        # ValueObject#sole_attribute`), and `value` is what the language
        # guarantees EVERY sole field answers to at runtime regardless of
        # its declared name (`Runtime::Value#method_missing`'s alias) —
        # so the shorthand simply declares it under the canonical name
        # directly. Type AND block together are refused: the block exists
        # to say what the fields are, and the type just said it — two
        # answers to one question is an authoring error, never a merge.
        # NEITHER type NOR block keeps its historical behavior untouched
        # (an empty attribute list — judged, or not, by the language
        # downstream, the same as before this parameter existed).
        def value_object(name, type = nil, &block)
          if type && block
            raise Malformed,
                  "#{name} declares both a type (#{type.inspect}) and a block — " \
                  "value_object #{name.inspect}, Type is sugar for a block declaring " \
                  "exactly one attribute named :value; write one form or the other, never both"
          end

          builder = ValueObjectBuilder.new(name, owner_value_objects: @value_objects + closed_sets)
          builder.attribute_impl(:value, type) if type
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
        # method's own comment for the pool shape; the three branches
        # below (exact owner / unambiguous single candidate / ambiguous)
        # are this construct's OWN refusal wording, not shared, since
        # `declared_by:` only exists here so far. UNRESOLVED (no
        # candidate yet, or `declared_by:` naming an aggregate that
        # hasn't declared it yet) is no longer a fourth branch that
        # raises HERE — see `#pending_chapter_given`, below, for why:
        # a chapter split across files can genuinely reference a
        # precondition a LATER file declares, and "not found among
        # what's loaded so far" cannot tell that apart from "genuinely
        # never declared" until every file has.
        def reference_named_chapter_given(description, declared_by:)
          verify_resolves_via!("given", "Aggregate", "owner_keyed")
          candidates = resolve_owner_keyed(@chapter_named_givens, description)

          named =
            if declared_by
              owner = Naming.demodulise(declared_by)
              candidates[owner] || pending_chapter_given(description, declared_by: owner)
            elsif candidates.size == 1
              candidates.values.first
            elsif candidates.empty?
              pending_chapter_given(description, declared_by: nil)
            else
              raise(Malformed,
                    "#{@name}'s given #{description.inspect} is ambiguous in this chapter — " \
                    "#{candidates.keys.join(', ')} each declare a DIFFERENT predicate under " \
                    "this same description; name which one with declared_by: (e.g. " \
                    "given(#{description.inspect}, declared_by: #{candidates.keys.first}))")
            end

          @named_givens[description] = named
        end

        # A CHAPTER MAY BE SPLIT ACROSS FILES — the SAME reason a query
        # hop's own cross-file target, a correlation key's own emitting
        # command, and an event's own declared shape are all resolved
        # once the whole chapter is assembled rather than refused the
        # moment one file's own bare reference outruns what's loaded so
        # far (`BluebookBuilder.validate_assembled!`'s own comment).
        #
        # Unlike those, though, a chapter-given's resolved value is not
        # a pass/fail check on an already-built IR — it IS part of the
        # referencing aggregate's own IR (`preconditions:` below), built
        # and handed off the moment THIS aggregate's own file finishes
        # loading, long before a later file might declare the real
        # thing. So this hands back a PLACEHOLDER `Given` — embedded
        # exactly where the resolved one would be, by Ruby object
        # reference, in this aggregate's own `preconditions` AND in any
        # command in this SAME aggregate that separately bare-references
        # the same description (`CommandBuilder#given`'s own hash-chain
        # read of this aggregate's `@named_givens`, the identical key) —
        # and queues the request in `@chapter_pending_givens`.
        # `BluebookBuilder#resolve_pending_chapter_givens!` MUTATES this
        # exact object in place, once every file has loaded, so every
        # existing reference to it (there is only ever the one object,
        # never a copy) sees the resolved fields simultaneously. Safe
        # because every real reader of a `Given` — refusal wording at
        # dispatch, `Aggregate`'s own lazy `-> { preconditions.map { ... } }`
        # IR accessor, docs — runs strictly after boot completes, never
        # mid-load; `judge_deferred!` resolves every pending chapter-given
        # before anything else touches this chapter's assembled IR.
        def pending_chapter_given(description, declared_by:)
          placeholder = Given.new(description: description, canonical: nil, predicate: nil)
          @chapter_pending_givens << { aggregate: @name, description: description,
                                        declared_by: declared_by, placeholder: placeholder }
          placeholder
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
          seal_correction_targets

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

        def self.build(name, chapter_named_givens: {}, chapter_pending_givens: [],
                       chapter_entity_named_givens: {}, chapter_entity_pending_givens: [], &block)
          builder = new(name, chapter_named_givens: chapter_named_givens, chapter_pending_givens: chapter_pending_givens,
                              chapter_entity_named_givens: chapter_entity_named_givens,
                              chapter_entity_pending_givens: chapter_entity_pending_givens)
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
                                      aggregate_name:                  @name,
                                      chapter_entity_named_givens:     @chapter_entity_named_givens,
                                      chapter_entity_pending_givens:   @chapter_entity_pending_givens,
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
      end
    end
  end
end
