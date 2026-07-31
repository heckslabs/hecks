module Hecksagain
  module Bluebook
    module DSL
      class EntityBuilder
        include AttributeCollector

        def initialize(name)
          @name     = name
          @commands = []
          @queries  = []
        end

        def description(value) = @description = value

        # A PIECE is known by a field exactly as a head is. `identified_by
        # :sequence` names the attribute and lets the whole value object stand
        # as the id ; `identified_by { sequence.value }` names the SCALAR inside
        # it, which is what an id actually is — a LedgerEntry is entry 3, not
        # entry {"value":3}. The block is recovered through the same extraction
        # port an aggregate's is, so the two constructs cannot drift apart in
        # how they spell an identity.
        def identified_by(field = nil, &path)
          field = Ports::Extraction.canonical(path) if path
          raise Malformed, "#{@name}.identified_by names no field" if field.to_s.empty?

          @identified_by = field.to_s.strip.to_sym
        end

        def command(name, &block)
          @commands << CommandBuilder.build(name, owner: @name, &block)
        end

        def query(name, &block)
          @queries << QueryBuilder.build(name, &block)
        end

        def lifecycle(field, default:, &block)
          @lifecycle = LifecycleBuilder.build(field, default: default, &block)
        end

        def build
          IR::Entity.declare(
            name:          @name,
            description:   @description,
            identified_by: @identified_by,
            attributes:    attributes,
            commands:      @commands,
            queries:       @queries,
            lifecycle:     @lifecycle
          )
        end

        def self.build(name, &block)
          builder = new(name)
          builder.instance_eval(&block) if block
          builder.build
        end
      end
    end
  end
end
