# AttributeCollector — the `attribute` / `list_of` pair, shared by every builder
# that can hold fields: aggregates, value objects, and commands.
#
# List shape is EXPLICIT. `list_of(X)` wraps the type in a marker the collector
# unwraps ; a bare type is always scalar. Nothing is inferred from the
# attribute's name.
#
#   attribute :name,     Name                 # scalar
#   attribute :toppings, list_of(Topping)     # list
#   attribute :currency, String, default: "USD"
module Hecksagain
  module DSL
    module AttributeCollector
      # Marker returned by list_of — unwrapped immediately by `attribute`.
      ListOf = Struct.new(:type)

      def attributes = @attributes ||= []

      def attribute(name, type = String, default: nil)
        list = type.is_a?(ListOf)
        attributes << IR::Attribute.new(
          name:    name,
          type:    list ? type.type : type,
          list:    list,
          default: default
        )
      end

      def list_of(type) = ListOf.new(type)
    end
  end
end
