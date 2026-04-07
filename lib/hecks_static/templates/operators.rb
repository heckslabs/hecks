# __DOMAIN_MODULE__::Runtime::Operators
#
# Comparison operator wrappers for the query DSL. Used as values in
# where conditions to express comparisons beyond simple equality.
# Each operator implements match?(actual) for in-memory filtering.

module __DOMAIN_MODULE__
  module Runtime
    module Operators
      module Operator; end

      class Gt
        include Operator
        attr_reader :value
        def initialize(value) = @value = value
        def match?(actual) = !actual.nil? && actual > @value
      end

      class Gte
        include Operator
        attr_reader :value
        def initialize(value) = @value = value
        def match?(actual) = !actual.nil? && actual >= @value
      end

      class Lt
        include Operator
        attr_reader :value
        def initialize(value) = @value = value
        def match?(actual) = !actual.nil? && actual < @value
      end

      class Lte
        include Operator
        attr_reader :value
        def initialize(value) = @value = value
        def match?(actual) = !actual.nil? && actual <= @value
      end

      class NotEq
        include Operator
        attr_reader :value
        def initialize(value) = @value = value
        def match?(actual) = actual != @value
      end

      class In
        include Operator
        attr_reader :value
        def initialize(value) = @value = value
        def match?(actual) = @value.include?(actual)
      end
    end
  end
end
