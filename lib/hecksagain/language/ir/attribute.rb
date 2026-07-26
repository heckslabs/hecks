# Attribute — one named, typed field on an aggregate, value object, or command.
#
# List shape is EXPLICIT, never inferred: `attribute :toppings, list_of(Topping)`
# is a list ; `attribute :name, Name` is scalar. The auto-list heuristic that
# guessed from pluralisation is not carried over from Hecks — it was a source of
# silent disagreement between the two parsers.
#
#   Attribute.new(name: :toppings, type: "Topping", list: true)
module Hecksagain
  module Language
    module IR
      class Attribute
        attr_reader :name, :type, :default

        def initialize(name:, type:, list: false, default: nil)
          @name    = name.to_sym
          @type    = type.to_s
          @list    = list
          @default = default
        end

        def list?   = @list
        def scalar? = !@list

        # True when the type is a Ruby primitive rather than a domain value object.
        PRIMITIVES = %w[String Integer Float TrueClass FalseClass].freeze
        def primitive? = PRIMITIVES.include?(@type)

        def to_h
          { name: @name, type: @type, list: @list, default: @default }
        end
      end
    end
  end
end
