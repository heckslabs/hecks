# Aggregate — a consistency boundary and, in this architecture, a PORT: its
# commands-in and events-out are the whole contract. Nothing else about it is
# addressable from outside.
#
# Value objects it uses are declared inside it. Its identity attribute defaults
# to :id ; `identified_by` overrides for singletons keyed by name.
#
#   Aggregate.new(name: "Pizza", attributes: [...], commands: [...])
module Hecksagain
  module IR
    class Aggregate
      attr_reader :name, :description, :attributes, :value_objects, :commands, :identified_by

      def initialize(name:, description: nil, attributes: [], value_objects: [],
                     commands: [], identified_by: :id)
        @name          = name.to_s
        @description   = description
        @attributes    = attributes
        @value_objects = value_objects
        @commands      = commands
        @identified_by = identified_by.to_sym
      end

      def attribute(named)    = @attributes.find { |a| a.name == named.to_sym }
      def value_object(named) = @value_objects.find { |v| v.name == named.to_s }
      def command(named)      = @commands.find { |c| c.name == named.to_s }

      # snake_case form used for storage keys and table names — the same rule
      # that turns a command name into a Ruby method.
      def storage_name = Naming.snake(@name)

      def to_h
        {
          name:          @name,
          description:   @description,
          identified_by: @identified_by,
          attributes:    @attributes.map(&:to_h),
          value_objects: @value_objects.map(&:to_h),
          commands:      @commands.map(&:to_h)
        }
      end
    end
  end
end
