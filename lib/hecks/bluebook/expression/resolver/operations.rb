# What each `Resolver` node does to the value it resolves: the arithmetic, text and list
# operations `interpret` applies, and the table that routes a node to its operation.
module Hecks
  module Bluebook
    module Expression
      # Reopens `Resolver` (see resolver.rb) for the operations `interpret` applies.
      module Resolver
        module_function

        # Integer is signed 64-bit; a sum outside the range is an evaluation fault (C3.3, C3.4).
        INT64_RANGE = (-(2**63))..((2**63) - 1)

        # Each node that acts on one already-resolved receiver value, in the order they are tried.
        # An operation is called as `(node, receiver_value, state, attrs)`.
        RECEIVER_OPERATIONS = {
          SignTest       => ->(node, value, _state, _attrs) { Resolver.apply_sign_test(node, value) },
          Empty          => ->(_node, value, _state, _attrs) { Resolver.emptiness_of(value) },
          ToS            => ->(_node, value, _state, _attrs) { Resolver.string_of(value) },
          Modulo         => lambda { |node, value, state, attrs|
            Resolver.apply_modulo(value, Resolver.interpret(node.divisor, state, attrs))
          },
          Size           => ->(_node, value, _state, _attrs) { Resolver.size_of(value) },
          MatchesRegex   => ->(node, value, _state, _attrs) { Resolver.matches_regex?(value, node.pattern, node.flags) },
          Presence       => ->(node, value, _state, _attrs) { Resolver.presence_of(node, value) },
          Assignment     => ->(node, value, _state, _attrs) { Resolver.assignment_of(node, value) },
          Split          => ->(node, value, _state, _attrs) { Resolver.split_value(value, node.separator) },
          Strip          => ->(node, value, _state, _attrs) { Resolver.strip_value(value, node.side) },
          Last           => ->(_node, value, _state, _attrs) { Resolver.last_of(value) },
          First          => ->(_node, value, _state, _attrs) { Resolver.first_of(value) },
          Find           => ->(node, value, state, attrs) { Resolver.found_of(node, value, state, attrs) },
          StartsWith     => ->(node, value, _state, _attrs) { Resolver.starts_with?(value, node.substring) },
          EndsWith       => ->(node, value, _state, _attrs) { Resolver.ends_with?(value, node.substring) },
          BlockPredicate => ->(node, value, state, attrs) { Resolver.evaluate_block_predicate(node, value, state, attrs) }
        }.freeze

        def add(left, right)
          lhs = require_number(left, "addition")
          rhs = require_number(right, "addition")
          sum = lhs + rhs
          if sum.is_a?(Integer)
            return sum if INT64_RANGE.cover?(sum)

            raise EvaluationError, "addition overflowed: #{lhs} + #{rhs} does not fit in a 64-bit integer"
          end
          return sum if sum.finite?

          raise EvaluationError, "addition overflowed: #{lhs} + #{rhs} is not a finite number"
        end

        def subtract(left, right)
          checked_arithmetic("subtraction", "-", left, right) { |lhs, rhs| lhs - rhs }
        end

        def multiply(left, right)
          checked_arithmetic("multiplication", "*", left, right) { |lhs, rhs| lhs * rhs }
        end

        # Integer operands floor toward negative infinity; a zero divisor faults like `.modulo`.
        def divide(left, right)
          raise EvaluationError, "divided by 0" if require_number(right, "division").zero?

          checked_arithmetic("division", "/", left, right) { |lhs, rhs| lhs / rhs }
        end

        # Applies `operation` to two numbers, refusing an Integer outside 64 bits or a Float that
        # is not finite, as `add` does.
        def checked_arithmetic(name, symbol, left, right)
          lhs = require_number(left, name)
          rhs = require_number(right, name)
          result = yield(lhs, rhs)
          return result if representable?(result)

          raise EvaluationError, "#{name} overflowed: #{lhs} #{symbol} #{rhs} #{overflow_reason(result)}"
        end

        def representable?(number) = number.is_a?(Integer) ? INT64_RANGE.cover?(number) : number.finite?

        def overflow_reason(number) = number.is_a?(Integer) ? "does not fit in a 64-bit integer" : "is not a finite number"

        def apply_sign_test(node, value)
          number = numeric(value)
          raise EvaluationError, "#{node.test} expects a number, got #{describe(value)}" unless number

          Evaluator.apply(node.operator, number, 0)
        end

        # The zero-check reads the coerced divisor, not the raw value or a `to_i` truncation.
        def apply_modulo(receiver_value, divisor_value)
          receiver = require_number(receiver_value, "modulo")
          divisor  = require_number(divisor_value, "modulo")
          raise EvaluationError, "divided by 0" if divisor.zero?

          receiver % divisor
        end

        def numeric(value)
          value if value.is_a?(Integer) || value.is_a?(Float)
        end

        def require_number(value, operation)
          numeric(value) ||
            raise(EvaluationError, "#{operation} expects a number, got #{describe(value)}")
        end

        def describe(value) = Rendering.describe(value)
      end
    end
  end
end
