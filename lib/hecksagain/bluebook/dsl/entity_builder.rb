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

        def command(name, &block)
          @commands << CommandBuilder.build(name, owner: @name, &block)
        end

        def query(name, &block)
          @queries << QueryBuilder.build(name, owner_attributes: attributes, &block)
        end

        def lifecycle(field, default:, &block)
          @lifecycle = LifecycleBuilder.build(field, default: default, &block)
        end

        def build
          resolve_pending_identity!
          Entity.declare(
            name:          @name,
            description:   @description,
            identified_by: @identity_paths,
            attributes:    attributes,
            commands:      @commands,
            queries:       @queries,
            lifecycle:     @lifecycle
          )
        end

        def self.build(name, owner_value_objects: [], &block)
          builder = new(name, owner_value_objects: owner_value_objects)
          builder.instance_eval(&block) if block
          builder.build
        end

        private

        # `identified_by`'s own resolution pool (AttributeCollector#resolve_
        # pending_identity!'s hook, S9) — a piece mints no value objects of
        # its own, so a bare field's own type resolves against its OWNER
        # aggregate's, passed in at declaration (`AggregateBuilder#entity`).
        def identity_pool = @owner_value_objects
      end
    end
  end
end
