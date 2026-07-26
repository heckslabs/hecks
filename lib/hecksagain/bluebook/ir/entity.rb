# Entity — an identity-bearing member inside an aggregate's boundary.
#
# The distinction Evans draws and most codebases lose : a VALUE OBJECT is its
# values (two Toppings with the same name and amount ARE the same topping), an
# ENTITY has identity that outlives its values (an OrderLine stays the same line
# when its quantity changes). Both live inside the root ; only the entity needs
# a key of its own.
#
#   entity "OrderLine" do
#     identified_by :sku
#     attribute :sku,      String
#     attribute :quantity, Integer
#     command "Restock" do ... end
#   end
#
# It may carry its own commands, queries and lifecycle — addressed through the
# parent (`Order.OrderLine.Restock`) because the root owns the boundary and the
# entity is reached through it, never around it.
#
# NO INVARIANTS. Hecks's entity builder collects them ; the interpreter's Entity
# has no field for them, so they would be authored and then silently dropped.
# Rules on an entity's values belong on a value object it holds, where they are
# actually enforced.
module Hecksagain
  module Bluebook
    module IR
      class Entity
        attr_reader :name, :description, :identified_by, :attributes,
                    :commands, :queries, :lifecycle

        def initialize(name:, description: nil, identified_by: nil, attributes: [],
                       commands: [], queries: [], lifecycle: nil)
          @name          = name.to_s
          @description   = description
          @identified_by = identified_by
          @attributes    = attributes
          @commands      = commands
          @queries       = queries
          @lifecycle     = lifecycle
        end

        def attribute(named) = @attributes.find { |a| a.name == named.to_sym }
        def command(named)   = @commands.find { |c| c.name == named.to_s }
        def query(named)     = @queries.find { |q| q.name == named.to_s }

        def to_h
          {
            name:          @name,
            description:   @description,
            identified_by: @identified_by&.to_s,
            attributes:    @attributes.map(&:to_h),
            commands:      @commands.map(&:to_h),
            queries:       @queries.map(&:to_h),
            lifecycle:     @lifecycle&.to_h
          }
        end
      end
    end
  end
end
