module Hecksagain
  module Bluebook
    module DSL
      class EntityBuilder
        include AttributeCollector
        include IdentityDeclaration

        def initialize(name, owner_value_objects: [])
          @name     = name
          @commands = []
          @queries  = []
          @entities = []
          @owner_value_objects = owner_value_objects
        end

        def description(value) = @description = value

        # THE SAME FIELD AggregateBuilder's OWN reference_to BUILDS — a
        # piece can hold a reference to another root exactly the way its
        # own head can (Card.assignee_id, a Team's own id), just never
        # to another PIECE, since there's no cross-piece addressing
        # anywhere in this language to resolve one against.
        def reference_to(type, as: nil)
          target = Naming.demodulise(type)
          attribute(as || default_reference_name(target), Reference.new(target))
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
          @commands << CommandBuilder.build(name, owner: @name, from: from, &block)
        end

        def query(name, &block)
          @queries << QueryBuilder.build(name, owner_attributes: attributes, &block)
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
          @entities << EntityBuilder.build(name, owner_value_objects: @owner_value_objects, &block)
        end

        def lifecycle(field, default:, &block)
          @lifecycle = LifecycleBuilder.build(field, default: default, &block)
        end

        def build
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
            lifecycle:     @lifecycle
          )
        end

        def self.build(name, owner_value_objects: [], &block)
          builder = new(name, owner_value_objects: owner_value_objects)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

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
