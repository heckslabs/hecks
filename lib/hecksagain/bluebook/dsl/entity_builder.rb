module Hecksagain
  module Bluebook
    module DSL
      class EntityBuilder
        include AttributeCollector

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
          attribute(as || :"#{Naming.snake(target)}_id", IR::Reference.new(target))
        end

        # A PIECE is known by a field, not by a whole value object.
        # `identified_by { sequence.value }` names the SCALAR inside it, which
        # is what an id actually is — a LedgerEntry is entry 3, not entry
        # {"value":3}. The block is recovered through the same extraction
        # port an aggregate's is, so the two constructs cannot drift apart in
        # how they spell an identity — INCLUDING the several-path form, which a
        # piece may say for the same reason a head may.
        def identified_by(field = nil, &path)
          if field
            raise Malformed, "#{@name}.identified_by takes a field name or a block, not both" if path

            @identity_field_pending = field
            return
          end

          raise Malformed, "#{@name}.identified_by names no field" unless path

          paths = Ports::Extraction.canonical(path).to_s.split(" ").reject(&:empty?)
          raise Malformed, "#{@name}.identified_by names no field" if paths.empty?

          @identity_paths = paths
        end

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
          IR::Entity.declare(
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

        def resolve_pending_identity!
          return unless @identity_field_pending

          @identity_paths = resolve_identity_field!(@identity_field_pending, @owner_value_objects, @name)
        end
      end
    end
  end
end
