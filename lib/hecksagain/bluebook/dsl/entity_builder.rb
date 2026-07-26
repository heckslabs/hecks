# EntityBuilder — evaluates an `entity "OrderLine" do ... end` block.
#
# Brought over from Hecks's DSL::EntityBuilder : same keywords, same nesting, so
# an entity written there reads here. It reuses the very builders the aggregate
# uses — CommandBuilder, QueryBuilder, LifecycleBuilder — because an entity
# declares the same things a root does, minus the boundary.
#
#   entity "OrderLine" do
#     identified_by :sku
#     attribute :sku,      String
#     attribute :quantity, Integer
#     lifecycle :state, default: "open" do
#       transition "Fulfil" => "fulfilled"
#     end
#   end
#
# `invariant` is deliberately ABSENT — see ir/entity.rb. Hecks collects them into
# a field the interpreter has no slot for, so authoring one here would look like
# a rule and enforce nothing.
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
          @commands << CommandBuilder.build(name, &block)
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
