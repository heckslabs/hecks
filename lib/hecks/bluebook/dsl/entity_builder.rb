require_relative "word_gate"
module Hecks
  module Bluebook
    module DSL
      class EntityBuilder
        GRAMMAR_CONTEXT = "Entity"

        include AttributeCollector
        include IdentityDeclaration
        include RuleReference
        include WordGate

        def initialize(name, owner_value_objects: [], owner_named_givens: {},
                       identity_name_prefix: nil, identity_value_object_installer: nil,
                       aggregate_name: nil, chapter_entity_named_givens: {}, chapter_entity_pending_givens: [])
          @name         = name
          @commands     = []
          @queries      = []
          @entities     = []
          @named_givens = {}
          @invariants   = []
          @owner_value_objects = owner_value_objects
          @identity_name_prefix = identity_name_prefix || Naming.demodulise(name)
          @identity_value_object_installer = identity_value_object_installer
          # THE AGGREGATE-WIDE cross-entity given pool — ONE hash, the
          # SAME object, threaded unchanged through every piece nested
          # under one aggregate however deep (the identical shape
          # `@owner_value_objects` already threads — see this class'
          # own `entity` comment). `given`'s own block form writes
          # through to it; a SIBLING piece's bare command-level
          # reference reads from it via `CommandBuilder#
          # reference_named_given`.
          @owner_named_givens = owner_named_givens
          # ONE LEVEL WIDER STILL — the CHAPTER-WIDE, ENTITY-SCOPED pool
          # (the piece analogue of `AggregateBuilder#@chapter_named_givens`,
          # one level down). `@aggregate_name` names THIS piece's own
          # root, so the write-through below can key itself
          # "AggregateName.EntityName" — the same dotted addressing
          # convention `declared_by:` already uses chapter-wide, one
          # level up. See `#given_impl`'s own comment for what this
          # closes and `docs/implemented/resolution-rules/
          # chapter-entity-given.md` for the full algorithm.
          @aggregate_name = aggregate_name || Naming.demodulise(name)
          @chapter_entity_named_givens   = chapter_entity_named_givens
          @chapter_entity_pending_givens = chapter_entity_pending_givens
          # DEFERRED CONSTRUCTION — see `AggregateBuilder#drain_pending!`'s
          # own comment; the identical mechanism, one level down, so a
          # nested piece's own commands (Dispatch inside Handler) see
          # every SIBLING entity/command/query this piece goes on to
          # declare, not just whatever came before it textually.
          @pending_entities = []
          @pending_commands = []
          @pending_queries  = []
        end

        def description(value) = @description = value

        # THE SAME FIELD AggregateBuilder's OWN reference_to BUILDS — a
        # piece can hold a reference to another root exactly the way its
        # own head can (Card.assignee_id, a Team's own id), just never
        # to another PIECE, since there's no cross-piece addressing
        # anywhere in this language to resolve one against.
        # RENAMED FROM `reference_to` — item #13's full metaprogrammed
        # dispatch (slice 4b). Bootstrap-reachable, in
        # GenericDispatch::BOOTSTRAP_CALLS_FALLBACK.
        def reference_to_impl(type, as: nil, optional: false)
          target = Naming.demodulise(type)
          relationship_attribute(target, :reference_to,
                                 as || default_reference_name(target), optional: optional)
        end

        # has_many_impl/has_one_impl are DSL declaration keywords a domain
        # author writes as bare has_many/has_one (matching belongs_to_impl
        # alongside them) — not real predicates, so renaming to many?/one?
        # per Naming/PredicatePrefix would break every bluebook that
        # declares one. New on Entity (Wave 6, identity-and-relationships
        # arc) — pieces never had relationship words before; named
        # `*_impl` to match AggregateBuilder's own siblings, item #13's
        # full metaprogrammed dispatch convention.
        # rubocop:disable Naming/PredicatePrefix
        def has_many_impl(type, as: nil, **options)
          unless options.empty?
            raise Malformed, "#{@name}.has_many takes no #{options.keys.first}: — an empty list already means none"
          end

          plural = Naming.demodulise(type)
          relationship_attribute(Naming.singularize(plural), :has_many,
                                 as || Naming.snake(plural).to_sym, list: true)
        end

        def has_one_impl(type, as: nil, optional: false)
          target = Naming.demodulise(type)
          relationship_attribute(target, :has_one, as || Naming.snake(target).to_sym, optional: optional)
        end
        # rubocop:enable Naming/PredicatePrefix

        def belongs_to_impl(type, as: nil, optional: false)
          target = Naming.demodulise(type)
          relationship_attribute(target, :belongs_to, as || Naming.snake(target).to_sym, optional: optional)
        end

        # A PIECE is known by a field, not by a whole value object.
        # `identified_by :sequence` names the SCALAR inside it, which is
        # what an id actually is — a LedgerEntry is entry 3, not entry
        # {"value":3}. `identified_by` itself is AttributeCollector's own
        # shared method (S9) — the two constructs cannot drift apart in
        # how they spell an identity, including composite
        # (`identified_by :branch_code, :box_number`), which a piece may
        # declare for the same reason a head may.

        # `from:` — see `AggregateBuilder#command`'s own comment; the
        # SAME guard, checked against this PIECE's own lifecycle field
        # (S10, ADR 0025 — a piece's own state machine is checkable the
        # same way a head's is).
        # RENAMED FROM `command`/`query`/`entity`/`lifecycle` (all below)
        # — item #13's full metaprogrammed dispatch (slice 4c), same
        # reasoning as AggregateBuilder's own siblings: bootstrap-
        # reachable, in BOOTSTRAP_CALLS_FALLBACK.
        def command_impl(name, from: nil, &block)
          @pending_commands << [name, from, block]
        end

        def query_impl(name, &block)
          @pending_queries << [name, block]
        end

        # S17, ADR 0026 — A PIECE NESTED INSIDE A PIECE. "A `Dispatch`
        # [has] no life outside its `Handler`" (the ADR's own words) —
        # the same reason `Member` nests inside `ValueObject`, one level
        # further in. `owner_value_objects` passes straight through
        # unchanged, not re-derived from this entity's own attributes —
        # a piece mints no value objects of its own at any depth, so a
        # NESTED piece's bare `identified_by :field` still resolves
        # against the SAME root aggregate's value objects an outer
        # piece's already does (`AggregateBuilder#entity`'s own comment
        # names this pool ; there is exactly one of them, however deep
        # the nesting goes).
        def entity_impl(name, &block)
          @pending_entities << [name, block]
        end

        def lifecycle_impl(field, default:, &block)
          @lifecycle = LifecycleBuilder.build(field, default: default, &block)
        end

        # A PRECONDITION SHARED ACROSS THIS PIECE'S OWN COMMANDS, DECLARED
        # ONCE — the same move `AggregateBuilder#given` already makes,
        # one level down. Real, live redundancy this closes: banking's
        # own `LedgerEntry.Amend`/`LedgerEntry.Reverse` each repeated
        # `given("customer is active") { parent.customer.status ==
        # "active" }` and `given("account is open") { parent.status ==
        # "open" }`, byte for byte, because a piece had no way to declare
        # either once and reference it back — only the AGGREGATE could.
        # DECLARE BEFORE THE COMMANDS THAT REFERENCE IT, the same
        # ordering `AggregateBuilder#given`'s own comment names — though
        # since ADR 0028, `command` only queues a descriptor and actually
        # builds at `#drain_pending!` time, well after this whole block
        # (including every `given` in it) has already run, so textual
        # order within the block no longer actually matters here; named
        # for the reader anyway, since `given`'s own resolution logic
        # (`CommandBuilder#reference_named_given`) still reads whatever
        # `@named_givens` holds AT THE COMMAND'S OWN BUILD TIME, not by
        # magic.
        # RENAMED FROM `given` — item #13's full metaprogrammed dispatch
        # (slice 4b), same reasoning as reference_to_impl above.
        #
        # BARE — NO BLOCK — REFERENCES ANOTHER PIECE'S OWN DECLARATION,
        # ANYWHERE IN THE CHAPTER, not just a sibling under this same
        # aggregate — one level wider than round 4's own cross-entity
        # sharing, mirroring `AggregateBuilder#given_impl`'s own
        # chapter-wide shape exactly one level down. Real, live corpus
        # this closes: `Account::LedgerEntry` and `SafeDepositBox::Visit`
        # — two pieces under two DIFFERENT aggregates — independently
        # typed `given("customer is active") { parent.customer.status ==
        # "active" }` byte for byte; neither the aggregate-level chapter
        # pool (a DIFFERENT canonical — bare `customer.status`, the
        # wrong scope for a piece's own command) nor the existing
        # same-aggregate cross-entity pool (`@owner_named_givens`, scoped
        # to ONE aggregate's own entity tree) could reach across the
        # aggregate boundary. Resolved against `@chapter_entity_named_
        # givens`, keyed "AggregateName.EntityName" — see
        # `#reference_named_chapter_entity_given`'s own comment for the
        # algorithm and `docs/implemented/resolution-rules/
        # chapter-entity-given.md` for the full write-up.
        #
        # `declared_by:` is a PLAIN STRING ("Account.LedgerEntry"), not a
        # constant — unlike `AggregateBuilder#given_impl`'s own
        # `declared_by:`, which names a real aggregate constant. A piece
        # has no first-class, independently-addressable reference
        # anywhere in this language (only its owning aggregate does);
        # inventing one to make this ONE argument spelling symmetrical
        # with the aggregate-level word is a real, separate, unscoped
        # feature this fix does not need — ships textual now, the same
        # way `admits:` shipped textual before its own constant-bridge
        # existed, revisited only if a genuine, separate need for
        # constant-addressed pieces shows up later.
        def given_impl(description, declared_by: nil, &predicate)
          return reference_named_chapter_entity_given(description, declared_by: declared_by) unless predicate

          named = build_rule(Given, description, predicate, owner_name: @name, word: "given",
                              extraction_failure: "its source could not be read, so no other runtime could ever evaluate it")
          @named_givens[description] = named
          # WRITE-THROUGH, first-declared-wins (`||=`) — a SECOND piece
          # under the same aggregate independently declaring the exact
          # same description stays purely local to itself (no silent
          # overwrite of whatever the first piece already shared;
          # real, live case a fuzzer or a future codemod could easily
          # surface: two pieces phrasing an UNRELATED rule identically
          # by coincidence, same as an aggregate-level given already
          # tolerates today).
          @owner_named_givens[description] ||= named
          # WRITE-THROUGH, PER OWNER — the chapter-wide analogue of the
          # line above, keyed by [description, this piece's own dotted
          # "Aggregate.Entity" name] rather than description alone, the
          # identical reasoning `AggregateBuilder#given_impl`'s own
          # chapter write-through gives: two DIFFERENT pieces (anywhere
          # in the chapter) independently declaring the SAME description
          # are two DISTINCT candidates a later bare reference chooses
          # between (via `declared_by:` once there is more than one),
          # never silently merged into one slot.
          @chapter_entity_named_givens[description] ||= {}
          @chapter_entity_named_givens[description]["#{@aggregate_name}.#{@name}"] ||= named
        end

        # A PIECE'S OWN SHAPE RULE (S10, ADR 0025's own "Rules" shape,
        # one level down from `ValueObjectBuilder#invariant`, whose
        # extraction/error pattern this mirrors) — checked against
        # EVERY INSTANCE of this piece the aggregate holds, not once
        # against the aggregate's own flat state
        # (`Admissibility#enforce_invariants`'s own recursive walk).
        # No reference-by-name form (unlike `given`) — no known corpus
        # need for a piece's own invariant to be shared with a SIBLING
        # piece yet; if that need shows up, it is `given`'s own
        # cross-entity write-through pattern to extend, not a reason to
        # invent a second one here speculatively.
        # RENAMED FROM `invariant` — item #13's full metaprogrammed
        # dispatch (slice 4b), same reasoning as given_impl above.
        def invariant_impl(description, &predicate)
          @invariants << build_rule(Invariant, description, predicate, owner_name: @name, word: "invariant",
                                     extraction_failure: "it would be a rule the IR cannot carry")
        end

        def build
          drain_pending!
          resolve_pending_identity!
          seal_lifecycle_guards
          install_closed_sets!
          Entity.declare(
            name:          @name,
            description:   @description,
            identified_by: @identity_paths,
            attributes:    attributes,
            commands:      @commands,
            queries:       @queries,
            entities:      @entities,
            preconditions: @named_givens.values,
            invariants:    @invariants,
            lifecycle:     @lifecycle
          )
        end

        def self.build(name, owner_value_objects: [], owner_named_givens: {},
                       identity_name_prefix: nil, identity_value_object_installer: nil,
                       aggregate_name: nil, chapter_entity_named_givens: {}, chapter_entity_pending_givens: [], &block)
          builder = new(name, owner_value_objects: owner_value_objects, owner_named_givens: owner_named_givens,
                              identity_name_prefix: identity_name_prefix,
                              identity_value_object_installer: identity_value_object_installer,
                              aggregate_name: aggregate_name,
                              chapter_entity_named_givens: chapter_entity_named_givens,
                              chapter_entity_pending_givens: chapter_entity_pending_givens)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

        # PRIMITIVE 2 (RuleReference#resolve_owner_keyed) — the CHAPTER-
        # WIDE, ENTITY-SCOPED analogue of `AggregateBuilder#
        # reference_named_chapter_given`; the three branches below are
        # this construct's OWN refusal wording, not shared, matching that
        # method's own precedent (`declared_by:` only exists on `given`
        # so far, at either scope). UNRESOLVED is deferred, not raised
        # here — see `#pending_chapter_entity_given`, below.
        #
        # WRITES THROUGH TO `@owner_named_givens` TOO — not just
        # `@named_givens` — or this piece resolving a description via the
        # WIDER, chapter pool would leave the NARROWER, same-aggregate
        # pool (`EntityBuilder#given_impl`'s own block-form write-through)
        # never populated for this description, breaking any SIBLING
        # piece's existing command-level bare reference
        # (`CommandBuilder#reference_named_given`) that depends on it —
        # real, live corpus: `SafeDepositBox::KeyIssuance.Return`'s own
        # bare `given("customer is active")` resolves through
        # `@owner_named_givens`, populated by `Visit`'s declaration
        # whether `Visit` types the predicate itself OR (now) references
        # `Account::LedgerEntry`'s instead — this write keeps that
        # working unchanged either way, `||=` so nothing here overrides
        # an actual local declaration if one is ever added later.
        def reference_named_chapter_entity_given(description, declared_by:)
          verify_resolves_via!("given", "Entity", "owner_keyed")
          candidates = resolve_owner_keyed(@chapter_entity_named_givens, description)

          named =
            if declared_by
              candidates[declared_by] || pending_chapter_entity_given(description, declared_by: declared_by)
            elsif candidates.size == 1
              candidates.values.first
            elsif candidates.empty?
              pending_chapter_entity_given(description, declared_by: nil)
            else
              raise(Malformed,
                    "#{@aggregate_name}::#{@name}'s given #{description.inspect} is ambiguous " \
                    "across the chapter's own pieces — #{candidates.keys.join(', ')} each declare " \
                    "a DIFFERENT predicate under this same description; name which one with " \
                    "declared_by: (e.g. given(#{description.inspect}, declared_by: " \
                    "#{candidates.keys.first.inspect}))")
            end

          @named_givens[description] = named
          @owner_named_givens[description] ||= named
        end

        # A CHAPTER MAY BE SPLIT ACROSS FILES — the identical reason
        # `AggregateBuilder#pending_chapter_given` defers rather than
        # raising the moment a bare reference outruns what's loaded so
        # far. Hands back a PLACEHOLDER `Given`, embedded by Ruby object
        # reference in this piece's own `preconditions`, and queues the
        # request in `@chapter_entity_pending_givens` —
        # `BluebookBuilder#resolve_pending_chapter_entity_givens!`
        # mutates it in place once every file in the chapter has loaded.
        def pending_chapter_entity_given(description, declared_by:)
          placeholder = Given.new(description: description, canonical: nil, predicate: nil)
          @chapter_entity_pending_givens << { entity: "#{@aggregate_name}.#{@name}", description: description,
                                               declared_by: declared_by, placeholder: placeholder }
          placeholder
        end

        # A PIECE'S OWN `one_of` LANDS ON ITS AGGREGATE. A type-position
        # `one_of("never_moved", "moved")` on an entity attribute
        # synthesizes a closed-set value object — and until this, that
        # object was built and then DROPPED: `Entity.declare` carries no
        # value objects, so the synthesized set existed nowhere in the
        # finished graph. The attribute stayed typed "Moved" with nothing
        # to resolve it: runtime admission had no closed set to enforce
        # (the one_of was decorative), and the fuzzer's ValueGenerator
        # crashed every run on the first domain to declare one — a chess
        # King/Rook's own castling flag — with `does not know primitive
        # type "Moved"`. Installed through the SAME hook an entity's own
        # identity value object already rides to the aggregate
        # (`identity_value_object_installer`, threaded unchanged through
        # nested pieces). Two sibling pieces synthesizing the same set
        # (King's and Rook's own `moved`) install it once; the same NAME
        # with a DIFFERENT member list is refused as the collision it is,
        # never first-wins silently.
        def install_closed_sets!
          return unless @identity_value_object_installer

          closed_sets.each do |value_object|
            existing = @owner_value_objects.find { |candidate| candidate.hecks_name == value_object.hecks_name }
            if existing
              next if existing.to_h == value_object.to_h

              raise Malformed,
                    "#{@name}'s one_of synthesizes #{value_object.hecks_name.inspect}, but the aggregate already " \
                    "holds a different #{value_object.hecks_name.inspect} — name the closed set's field differently"
            end

            @identity_value_object_installer.call(value_object)
          end
        end

        # See `AggregateBuilder#drain_pending!`'s own comment — the
        # identical mechanism, one level down. Entities first and fully
        # built (so a nested command's own `append:` resolution can read
        # a sibling piece's `.attributes`), then commands, then queries.
        def drain_pending!
          @entities = @pending_entities.map do |name, block|
            EntityBuilder.build(name, owner_value_objects:             @owner_value_objects,
                                      owner_named_givens:              @owner_named_givens,
                                      identity_name_prefix:            "#{@identity_name_prefix}#{Naming.demodulise(name)}",
                                      identity_value_object_installer: @identity_value_object_installer,
                                      aggregate_name:                  @aggregate_name,
                                      chapter_entity_named_givens:     @chapter_entity_named_givens,
                                      chapter_entity_pending_givens:   @chapter_entity_pending_givens,
                                &block)
          end

          @commands = @pending_commands.map do |name, from, block|
            CommandBuilder.build(name, owner: @name, from: from, named_givens: @named_givens,
                                        owner_attributes: attributes,
                                        owner_constructs: @owner_value_objects + @entities,
                                        entity_shared_givens: @owner_named_givens, &block)
          end

          @queries = @pending_queries.map do |name, block|
            QueryBuilder.build(name, owner_attributes: attributes, &block)
          end
        end

        # See `AggregateBuilder#seal_lifecycle_guards`'s own comment —
        # the identical check, one level down.
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

        # `identified_by`'s own resolution pool (AttributeCollector#resolve_
        # pending_identity!'s hook, S9) — a piece mints no value objects of
        # its own, so a bare field's own type resolves against its OWNER
        # aggregate's, passed in at declaration (`AggregateBuilder#entity`).
        def identity_pool = @owner_value_objects

        def identity_value_object_name = "#{@identity_name_prefix}Identity"

        def install_identity_value_object!(value_object)
          @identity_value_object_installer&.call(value_object)
          @owner_value_objects << value_object unless @owner_value_objects.include?(value_object)
        end
      end
    end
  end
end
