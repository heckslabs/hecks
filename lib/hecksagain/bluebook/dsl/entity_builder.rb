require_relative "word_gate"
module Hecksagain
  module Bluebook
    module DSL
      class EntityBuilder
        GRAMMAR_CONTEXT = "Entity"

        include AttributeCollector
        include IdentityDeclaration
        include RuleReference
        include WordGate

        def initialize(name, owner_value_objects: [], owner_named_givens: {})
          @name         = name
          @commands     = []
          @queries      = []
          @entities     = []
          @named_givens = {}
          @invariants   = []
          @owner_value_objects = owner_value_objects
          # THE AGGREGATE-WIDE cross-entity given pool — ONE hash, the
          # SAME object, threaded unchanged through every piece nested
          # under one aggregate however deep (the identical shape
          # `@owner_value_objects` already threads — see this class'
          # own `entity` comment). `given`'s own block form writes
          # through to it; a SIBLING piece's bare command-level
          # reference reads from it via `CommandBuilder#
          # reference_named_given`.
          @owner_named_givens = owner_named_givens
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
        def reference_to(type, as: nil)
          target = Naming.demodulise(type)
          attribute_impl(as || default_reference_name(target), Reference.new(target))
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
        def command(name, from: nil, &block)
          @pending_commands << [name, from, block]
        end

        def query(name, &block)
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
        def entity(name, &block)
          @pending_entities << [name, block]
        end

        def lifecycle(field, default:, &block)
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
        def given(description, &predicate)
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
        def invariant(description, &predicate)
          @invariants << build_rule(Invariant, description, predicate, owner_name: @name, word: "invariant",
                                     extraction_failure: "it would be a rule the IR cannot carry")
        end

        def build
          drain_pending!
          resolve_pending_identity!
          seal_lifecycle_guards
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

        def self.build(name, owner_value_objects: [], owner_named_givens: {}, &block)
          builder = new(name, owner_value_objects: owner_value_objects, owner_named_givens: owner_named_givens)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

        # See `AggregateBuilder#drain_pending!`'s own comment — the
        # identical mechanism, one level down. Entities first and fully
        # built (so a nested command's own `append:` resolution can read
        # a sibling piece's `.attributes`), then commands, then queries.
        def drain_pending!
          @entities = @pending_entities.map do |name, block|
            EntityBuilder.build(name, owner_value_objects: @owner_value_objects,
                                      owner_named_givens:  @owner_named_givens, &block)
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
      end
    end
  end
end
