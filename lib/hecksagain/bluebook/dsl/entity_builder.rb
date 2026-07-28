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

        def description(value)   = @description = value
        def identified_by(field) = @identified_by = field.to_sym

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
          IR::Entity.new(
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
