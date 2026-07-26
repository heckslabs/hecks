# Instance — one live aggregate: its identity plus its current attribute state.
#
# Attributes are readable as methods, which is what lets a bluebook given read
# as domain language: `given("max 10 toppings") { toppings.size < 10 }` is
# instance_eval'd here, so `toppings` resolves to the actual list.
#
# Defaults come from the IR — a list attribute starts as [], a scalar starts at
# its declared default. The runtime never invents a shape the bluebook did not
# declare.
#
#   Instance.new(aggregate: pizza_ir, id: "pizza-1a2b")
module Hecksagain
  module Runtime
    class Instance
      attr_reader :aggregate, :id
      attr_accessor :state

      def initialize(aggregate:, id:, state: nil)
        @aggregate = aggregate
        @id        = id
        @state     = state || self.class.defaults(aggregate)
      end

      # Starting state straight from the IR: [] for lists, declared default
      # otherwise.
      def self.defaults(aggregate)
        aggregate.attributes.each_with_object({}) do |attr, acc|
          acc[attr.name] = attr.list? ? [] : attr.default
        end
      end

      def [](name) = @state[name.to_sym]

      # Declared-ness, not presence of a value: an attribute the bluebook
      # declares is known even when it is nil, and a name it does not declare
      # is unknown even if something else would answer to it.
      def key?(name) = @state.key?(name.to_sym)

      # Not endless — Ruby forbids that form for setter methods.
      def []=(name, value)
        @state[name.to_sym] = value
      end

      def method_missing(name, *args)
        return @state[name] if @state.key?(name)

        super
      end

      def respond_to_missing?(name, include_private = false)
        @state.key?(name) || super
      end

      def to_h = { id: @id }.merge(@state)

      def inspect
        fields = @state.map { |k, v| "#{k}=#{v.inspect}" }.join(" ")
        "#<#{@aggregate.name} #{@id} #{fields}>"
      end
    end
  end
end
