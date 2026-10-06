require_relative "../../rendering"
require_relative "../errors"
require_relative "../refusal_wording"
require_relative "../value"

module Hecks
  module Runtime
    class CommandRules
      module Arithmetic
        # What arithmetic does to its operands before combining them: unwrapping a value object
        # to its number, picking the one numeric field two value objects share, and wording the
        # refusal when an operand is not a number. Mixed into {Arithmetic}.
        module Operands
          private

          def value_objects?(current, amount)
            current.is_a?(Value) && amount.is_a?(Value)
          end

          def sign_symbol(sign)
            sign.positive? ? "+" : "-"
          end

          # Refuses an amount, then a current value, that is not a number.
          def refuse_non_numeric!(verb, target, amount, current)
            return if amount.is_a?(Numeric) && current.is_a?(Numeric)

            site, offered = amount.is_a?(Numeric) ? ["arithmetic_current", current] : ["arithmetic_amount", amount]
            raise TypeMismatch, RefusalWording.render_site("TypeMismatch", site,
                                                           op: verb, target: target, offered: Rendering.describe(offered))
          end

          # Refuses a product with a side that is not a number, offering the side that is not.
          def refuse_unmultipliable!(target, amount, current)
            return if amount.is_a?(Numeric) && current.is_a?(Numeric)

            raise TypeMismatch, RefusalWording.render_site("TypeMismatch", "arithmetic_amount",
                                                           op: "multiply", target: target,
                                                           offered: Rendering.describe(current.is_a?(Numeric) ? amount : current))
          end

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
            field = shared_numeric_field(current, amount, target, oper)
            current.with(field, yield(current[field], amount[field]))
          end

          # The one numeric field both value objects carry; refuses when there is not exactly one.
          def shared_numeric_field(current, amount, target, oper)
            current_fields = current.to_h
            amount_fields  = amount.to_h
            shared_numeric = current_fields.keys.select do |field|
              current_fields[field].is_a?(Numeric) && amount_fields[field].is_a?(Numeric)
            end
            return shared_numeric.first if shared_numeric.size == 1

            raise TypeMismatch,
                  RefusalWording.render_site("TypeMismatch", "arithmetic_shared_field", op: oper, target: target)
          end

          # Bounds a value object's one numeric field into `[min, max]`.
          def clamp_value_object(current, min, max, target)
            fields = current.to_h
            field  = fields.keys.find { |f| fields[f].is_a?(Numeric) } or
              raise TypeMismatch, RefusalWording.render_site("TypeMismatch", "arithmetic_current",
                                                             op: "clamp", target: target, offered: Rendering.describe(current))
            current.with(field, fields[field].clamp(min, max))
          end

          def refuse_clamp_current!(current, target)
            raise TypeMismatch, RefusalWording.render_site("TypeMismatch", "arithmetic_current",
                                                           op: "clamp", target: target, offered: Rendering.describe(current))
          end
        end
      end
    end
  end
end
