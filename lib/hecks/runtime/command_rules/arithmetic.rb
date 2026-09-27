require_relative "../../rendering"
require_relative "../errors"
require_relative "../refusal_wording"
require_relative "../value"

module Hecks
  module Runtime
    class CommandRules
      # The arithmetic half of mutation: source resolution, and how
      # increment/decrement land on an Integer or a one-numeric-field value object.
      module Arithmetic
        # Mirrors Vocabulary::MutationOp (language/bluebook/vocabulary.bluebook) so
        # increment/decrement's sign cannot drift from the language's own definition.
        # Ops with no arithmetic (set, append, multiply, clamp, remove, delegate,
        # corrects) declare an empty sign, which reads here as nil.
        MutationOp = Struct.new(:name, :sign, keyword_init: true)

        MUTATION_OPS = Hecks::Vocabulary.rows("MutationOp").map do |row|
          MutationOp.new(name: row["name"], sign: row["sign"].empty? ? nil : Integer(row["sign"]))
        end.freeze

        # Resolves a mutation's source: an argument's value for a Symbol, the
        # literal itself otherwise.
        #
        # Looked up unconditionally, with no `args.key?` guard, so an absent
        # optional argument resolves to nil instead of falling back to the
        # symbol itself as a value.
        #
        # @param source [Symbol, Object] a Symbol names a command argument, anything else
        #   is returned as is
        # @param args [Hash{Symbol => Object}] the normalized command arguments
        # @return [Object, nil] the argument's value, nil if omitted, or `source` itself
        def resolve_source(source, args)
          return args[source] if source.is_a?(Symbol)

          source
        end

        # Adds or subtracts `amount` from an attribute's current value, on a bare
        # number or the one numeric field two value objects share.
        #
        # @param current [Numeric, Runtime::Value, nil] pre-dispatch value; nil (unset) is 0
        # @param amount [Numeric, Runtime::Value] amount to move by; combined field by field
        #   with a value-object `current`, else unwrapped to its single numeric field
        # @param target [Symbol, String] attribute name, used only to word a refusal
        # @param sign [Integer] 1 to increment, -1 to decrement
        # @return [Numeric, Runtime::Value] a `Runtime::Value` when both sides are value
        #   objects, otherwise a bare number the caller re-wraps
        # @raise [Runtime::TypeMismatch] if `amount`/`current` aren't numeric, or the two
        #   value objects share no single numeric field
        # @raise [Runtime::InvariantViolation] if a value-object result breaks an invariant
        # @raise [Bluebook::Expression::EvaluationError] if the result doesn't fit a signed
        #   64-bit Integer, or is a non-finite Float
        def arithmetic(current, amount, target, sign)
          op = sign.positive? ? "increment" : "decrement"
          current ||= 0

          return arithmetic_value_object(current, amount, target, sign, op) if current.is_a?(Value) && amount.is_a?(Value)

          # A VO-typed attribute with no declared default is genuinely absent
          # here (`current` is 0, not a Value), so `amount` still needs
          # unwrapping to compare against a bare number.
          amount = unwrap_single_numeric_field(amount) if amount.is_a?(Value)

          unless amount.is_a?(Numeric)
            raise TypeMismatch, RefusalWording.render_site("TypeMismatch", "arithmetic_amount",
                                                           op: op, target: target, offered: Rendering.describe(amount))
          end
          unless current.is_a?(Numeric)
            raise TypeMismatch, RefusalWording.render_site("TypeMismatch", "arithmetic_current",
                                                           op: op, target: target, offered: Rendering.describe(current))
          end

          bounded(current + (sign * amount), op, current, sign * amount, sign.positive? ? "+" : "-")
        end

        # An effect's arithmetic is held to the same value model an expression's is:
        # Integer signed 64-bit, Float finite. Out of range is an evaluation fault,
        # not a refusal (ADR checked_add/checked_sub/checked_mul wording).
        INT64_RANGE = (-(2**63))..((2**63) - 1)

        # Passes an arithmetic result through only if it fits the value model: a signed
        # 64-bit Integer or a finite Float.
        #
        # @param result [Numeric] the computed value to check
        # @param oper [String] the op's name, the first word of the fault message
        # @param lhs [Numeric] the left operand, quoted in the fault message
        # @param rhs [Numeric] the right operand; its absolute value is quoted
        # @param symbol [String] the operator to print between the operands
        # @return [Numeric] `result`, unchanged
        # @raise [Bluebook::Expression::EvaluationError] if an Integer result is outside
        #   `INT64_RANGE`, or a Float result is NaN or infinite
        def bounded(result, oper, lhs, rhs, symbol)
          if result.is_a?(Integer)
            return result if INT64_RANGE.cover?(result)

            raise Bluebook::Expression::EvaluationError,
                  "#{oper} overflowed: #{lhs} #{symbol} #{rhs.abs} does not fit in a 64-bit integer"
          end
          return result unless result.is_a?(Float) && !result.finite?

          raise Bluebook::Expression::EvaluationError,
                "#{oper} overflowed: #{lhs} #{symbol} #{rhs.abs} is not a finite number"
        end

        # Adds or subtracts on the one numeric field two value objects share, answering
        # a new value object of `current`'s type.
        #
        # @param current [Runtime::Value] the attribute's pre-dispatch value
        # @param amount [Runtime::Value] how much to move by
        # @param target [Symbol, String] attribute name, used only to word a refusal
        # @param sign [Integer] 1 to add, -1 to subtract
        # @param oper [String] `"increment"` or `"decrement"`, for refusal/fault wording
        # @return [Runtime::Value] a copy of `current` with the shared field replaced
        # @raise [Runtime::TypeMismatch] if the two don't share exactly one numeric field,
        #   or the rebuilt value object refuses the new field value
        # @raise [Runtime::InvariantViolation] if the new field value breaks an invariant
        # @raise [Bluebook::Expression::EvaluationError] if the result doesn't fit a signed
        #   64-bit Integer, or is a non-finite Float
        def arithmetic_value_object(current, amount, target, sign, oper)
          current_fields = current.to_h
          amount_fields  = amount.to_h
          # A synthesized value-object wrapper around a bare numeric attribute
          # always carries exactly one numeric field.
          shared_numeric = current_fields.keys.select do |field|
            current_fields[field].is_a?(Numeric) && amount_fields[field].is_a?(Numeric)
          end
          unless shared_numeric.size == 1
            raise TypeMismatch,
                  RefusalWording.render_site("TypeMismatch", "arithmetic_shared_field", op: oper, target: target)
          end

          field = shared_numeric.first
          current.with(field, bounded(current[field] + (sign * amount[field]), oper,
                                      current[field], amount[field], sign.positive? ? "+" : "-"))
        end

        # Looks up whether a mutation op adds or subtracts, from the generated
        # `MUTATION_OPS` table.
        #
        # Not a bare `.find(...)&.sign || -1`: that would silently answer
        # decrement's sign both for an unknown op and for a real op declared
        # with no sign at all (set/append/multiply/clamp/remove/delegate/corrects).
        #
        # @param oper [Symbol, String] the mutation op's name, such as `:increment`
        # @return [Integer] 1 for increment, -1 for decrement
        # @raise [Runtime::WiringError] if the op is unknown, or is declared with no sign
        def sign_of(oper)
          MUTATION_OPS.find { |candidate| candidate.name == oper.to_s }&.sign ||
            raise(WiringError, "no sign declared for mutation op #{oper.inspect} — add one before calling #sign_of")
        end

        # Scales an attribute's current value by `amount`, on a bare number or on the
        # one numeric field two value objects share.
        #
        # @param current [Numeric, Runtime::Value, nil] pre-dispatch value; nil (unset) is 0
        # @param amount [Numeric, Runtime::Value] the factor; combined field by field with a
        #   value-object `current`, else unwrapped to its single numeric field
        # @param target [Symbol, String] attribute name, used only to word a refusal
        # @return [Numeric, Runtime::Value] the product: a `Runtime::Value` when both sides
        #   are value objects, otherwise a bare number the caller re-wraps
        # @raise [Runtime::TypeMismatch] if `amount`/`current` aren't numeric, or the two
        #   value objects share no single numeric field
        # @raise [Runtime::InvariantViolation] if a value-object result breaks an invariant
        # @raise [Bluebook::Expression::EvaluationError] if the product doesn't fit a signed
        #   64-bit Integer, or is a non-finite Float
        def multiply(current, amount, target)
          current ||= 0

          if current.is_a?(Value) && amount.is_a?(Value)
            return combine_value_object(current, amount, target, "multiply") do |c, a|
              bounded(c * a, "multiply", c, a, "*")
            end
          end

          # Same absent-current, VO-wrapped-amount gap as #arithmetic, above.
          amount = unwrap_single_numeric_field(amount) if amount.is_a?(Value)

          unless amount.is_a?(Numeric) && current.is_a?(Numeric)
            raise TypeMismatch, RefusalWording.render_site("TypeMismatch", "arithmetic_amount",
                                                           op: "multiply", target: target,
                                                           offered: Rendering.describe(current.is_a?(Numeric) ? amount : current))
          end

          bounded(current * amount, "multiply", current, amount, "*")
        end

        # Bounds an attribute's current value into `[min, max]`, on a bare number or on
        # the one numeric field the wrapping value object carries.
        #
        # @param current [Numeric, Runtime::Value, nil] pre-dispatch value; nil (unset) is 0
        # @param bounds [Array<Numeric>] the two-element `[min, max]` range to clamp into
        # @param target [Symbol, String] attribute name, used only to word a refusal
        # @return [Numeric, Runtime::Value] the clamped value: a `Runtime::Value` when
        #   `current` is one, otherwise a bare number the caller re-wraps
        # @raise [Runtime::TypeMismatch] if `current` is a value object with no single
        #   numeric field, or is neither numeric nor a value object
        def clamp(current, bounds, target)
          min, max = bounds
          current ||= 0
          if current.is_a?(Value)
            fields = current.to_h
            field  = fields.keys.find { |f| fields[f].is_a?(Numeric) } or
              raise TypeMismatch, RefusalWording.render_site("TypeMismatch", "arithmetic_current",
                                                             op: "clamp", target: target, offered: Rendering.describe(current))
            return current.with(field, fields[field].clamp(min, max))
          end

          unless current.is_a?(Numeric)
            raise TypeMismatch, RefusalWording.render_site("TypeMismatch", "arithmetic_current",
                                                           op: "clamp", target: target, offered: Rendering.describe(current))
          end

          current.clamp(min, max)
        end

        private

        # Only meaningful once `current` is known not to itself be a Value (the
        # both-sides-are-Values branch owns that case in each caller). Refuses
        # rather than guesses when more than one field is numeric.
        def unwrap_single_numeric_field(value)
          fields = value.to_h
          numeric_fields = fields.keys.select { |field| fields[field].is_a?(Numeric) }
          return value unless numeric_fields.size == 1

          fields[numeric_fields.first]
        end

        def combine_value_object(current, amount, target, oper)
          current_fields = current.to_h
          amount_fields  = amount.to_h
          shared_numeric = current_fields.keys.select do |field|
            current_fields[field].is_a?(Numeric) && amount_fields[field].is_a?(Numeric)
          end
          unless shared_numeric.size == 1
            raise TypeMismatch,
                  RefusalWording.render_site("TypeMismatch", "arithmetic_shared_field", op: oper, target: target)
          end

          field = shared_numeric.first
          current.with(field, yield(current[field], amount[field]))
        end
      end
    end
  end
end
