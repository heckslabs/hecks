# AggregateBuilder — evaluates an `aggregate "Pizza" do ... end` block.
#
# Value objects are declared INSIDE the aggregate that uses them. An
# aggregate-level `reference_to X` points at another root by its identity and
# lands as a plain `x_id` attribute — references are by identity, never by
# embedding.
#
#   aggregate "Pizza" do
#     description "A pizza with toppings, sold to a customer"
#     attribute :name,     Name
#     attribute :toppings, list_of(Topping)
#     value_object("Topping") { ... }
#     command("AddTopping") { ... }
#   end
module Hecksagain
  module DSL
    class AggregateBuilder
      include AttributeCollector

      def initialize(name)
        @name          = name
        @value_objects = []
        @commands      = []
        @identified_by = :id
      end

      def description(value)   = @description = value
      def identified_by(field) = @identified_by = field.to_sym

      # Another root, referenced by its global identity.
      def reference_to(type)
        attribute(:"#{snake(type.to_s)}_id", String)
      end

      def value_object(name, &block)
        @value_objects << ValueObjectBuilder.build(name, &block)
      end

      def command(name, &block)
        @commands << CommandBuilder.build(name, &block)
      end

      def build
        IR::Aggregate.new(
          name:          @name,
          description:   @description,
          attributes:    attributes,
          value_objects: @value_objects,
          commands:      @commands,
          identified_by: @identified_by
        )
      end

      def self.build(name, &block)
        builder = new(name)
        builder.instance_eval(&block) if block
        builder.build
      end

      private

      def snake(text)
        text.gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
      end
    end
  end
end
