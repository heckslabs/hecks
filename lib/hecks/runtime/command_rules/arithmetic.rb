require_relative "../../rendering"
require_relative "../errors"
require_relative "../refusal_wording"
require_relative "../value"

module Hecks
  module Runtime
    class CommandRules
      # The arithmetic half of mutation: what a source resolves to, and how
      # increment/decrement land on an Integer or a one-numeric-field value
      # object.
      module Arithmetic
        # The ops Runtime::CommandInterpreter applies — Vocabulary::MutationOp
        # (language/bluebook/vocabulary.bluebook), read off the generated
        # table, so increment/decrement's sign cannot drift from what the
        # language says each op means. Every other op (set, append, multiply,
        # clamp, remove, delegate, corrects) declares an empty sign — it does
        # no add-or-subtract arithmetic — which reads here as nil.
        MutationOp = Struct.new(:name, :sign, keyword_init: true)

        MUTATION_OPS = Hecks::Vocabulary.rows("MutationOp").map do |row|
          MutationOp.new(name: row["name"], sign: row["sign"].empty? ? nil : Integer(row["sign"]))
        end.freeze

        # Reads what a mutation's source means: an argument's value for a Symbol, the literal
        # itself for anything else.
        #
        # A mutation's source is either the name of an argument or a literal, and
        # the two are told apart by type : a Symbol is always a name, a String or a
        # number is always a value. Checked across all eight chapters — `to: :name`
        # and `to: "sold"`, never a Symbol meant as a value.
        #
        # The lookup is unconditional, with no `&& args.key?(source)` guard: such a
        # guard makes an absent argument fall through to `source` and return the symbol
        # itself as the value. `Customer.Register` without its `name` would set name to
        # the literal `:name`, coercion would meet a Symbol where a PersonName belongs,
        # and the refusal would read "name is a PersonName — pass its fields as an
        # object, not :name" — a message describing a mistake the caller had not
        # made. The real mistake, an absent argument, would never be the one refused,
        # which is what fuzz surfaced.
        #
        # An absent argument resolving to nil is correct, not pending work. The
        # language can say which arguments are optional (`attribute ...,
        # optional: true` — `CommandBuilder#attribute_impl`,
        # `attribute_collector.rb`): `sets` sources correctly from
        # an optional attribute, resolving absent to nil exactly as this
        # method does, and refusing it here would be wrong, not merely
        # undone work — `TillRoom::Till.TakeIn`'s own `note` (spec/
        # fixtures/till.bluebook) and Banking's `CardPayment.Authorize`'s
        # `tags` (payment_cards.bluebook) are real, live commands whose
        # `sets` mutation is deliberately sourced from an optional
        # attribute the caller may omit — `spec/runtime/command_rules_spec
        # .rb`'s own "says an absent optional argument is nil, not the
        # name of the argument" pins exactly this as correct, not pending.
        # The meta-domain's own self-hosted commands (Command.Declare's
        # `role`/`goal`/`provenance`/`from`/`position`, and ~35 more sites
        # across the language) all lean on the identical pattern — nil is
        # the right answer for a `sets` sourced from a declared-optional
        # attribute the caller left out, every time.
        #
        # The one narrow gap that leaves — a `sets` source Symbol naming
        # nothing the command declares at all (a typo, not an optional
        # argument), which would resolve to nil here, indistinguishable
        # from a legitimate optional absence — is closed at build time
        # instead of here: `CommandBuilder#refuse_unknown_argument_sources!`
        # refuses it the moment the `.bluebook` file loads, mirroring
        # `AggregateBuilder#seal_query_argument`'s identical check for a
        # query's own where-clause argument. This function stays a pure,
        # unconditional lookup because by the time any mutation reaches
        # it, the source has already been proven to name either a real,
        # possibly-optional argument, or a StateRef/literal; there is
        # nothing left here to refuse.
        #
        # @param source [Symbol, Object] a mutation's source: a Symbol names a command argument,
        #   anything else (String, Numeric, Array, Hash, `StateRef`) is returned as is
        # @param args [Hash{Symbol => Object}] the normalized command arguments
        # @return [Object, nil] the named argument's value, nil when the caller left that
        #   argument out; otherwise `source` itself
        def resolve_source(source, args)
          return args[source] if source.is_a?(Symbol)

          source
        end

        # Adds or subtracts `amount` from an attribute's current value, on a bare number or on
        # the one numeric field two value objects share.
        #
        # @param current [Numeric, Runtime::Value, nil] the attribute's pre-dispatch value; nil
        #   (never set) counts as 0
        # @param amount [Numeric, Runtime::Value] how much to move by; a value object is combined
        #   field by field with a value-object `current`, and otherwise unwrapped to its single
        #   numeric field
        # @param target [Symbol, String] name of the attribute, used only to word a refusal
        # @param sign [Integer] 1 to increment, -1 to decrement, as `sign_of` answers
        # @return [Numeric, Runtime::Value] the new value: a `Runtime::Value` when both sides
        #   are value objects, otherwise a bare number the caller re-wraps
        # @raise [Runtime::TypeMismatch] if `amount` or `current` is not numeric, or two value
        #   objects do not share exactly one numeric field
        # @raise [Runtime::InvariantViolation] if a value-object result breaks one of its own
        #   invariants
        # @raise [Bluebook::Expression::EvaluationError] if the result does not fit a signed
        #   64-bit Integer, or is a non-finite Float
        def arithmetic(current, amount, target, sign)
          op = sign.positive? ? "increment" : "decrement"
          current ||= 0

          return arithmetic_value_object(current, amount, target, sign, op) if current.is_a?(Value) && amount.is_a?(Value)

          # `current` genuinely absent (no declared default, never set) and
          # `amount` arrives VO-wrapped — a real command argument typed the
          # same as the attribute, but with nothing to combine field-by-
          # field against yet (that is what `arithmetic_value_object`,
          # above, is for once both sides carry real fields). Before this,
          # falling straight to `unless amount.is_a?(Numeric)` below
          # refused with "increment needs an Integer, got 500" — true of
          # nothing: 500 is exactly the Integer it asked for, just still
          # wearing the Money wrapper the command's own declared attribute
          # type put it in. Unwrapped here, the same shape #clamp already
          # falls through to for an absent VO-typed attribute
          # (`current ||= 0`, then a raw scalar) — the mutation applier
          # re-wraps the raw result into the declared VO type on write,
          # the same way it already does for clamp's own result.
          amount = unwrap_single_numeric_field(amount) if amount.is_a?(Value)

          # Widened from Integer to Numeric (migration plan task 4, i106):
          # miette's organ math increments a Float (`increment: 0.02`) --
          # the raw, non-value-object path only ever mattered for Integer
          # counters before this corpus existed. Integer stays the common
          # case; Float is now accepted the same way.
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

        # C3.3/C3.4 — an effect's arithmetic is held to the same value
        # model an expression's is: Integer is signed 64-bit, Float is
        # finite. A result outside that is an evaluation fault (never a
        # refusal, C8.3), worded as the Rust kernel's own generated
        # `checked_add`/`checked_sub`/`checked_mul` word it.
        INT64_RANGE = (-(2**63))..((2**63) - 1)

        # Passes an arithmetic result through only if it fits the value model: a signed 64-bit
        # Integer or a finite Float.
        #
        # @param result [Numeric] the computed value to check
        # @param oper [String] the op's name (`"increment"`, `"decrement"`, `"multiply"`),
        #   the first word of the fault message
        # @param lhs [Numeric] the left operand, quoted in the fault message
        # @param rhs [Numeric] the right operand; its absolute value is quoted
        # @param symbol [String] the operator to print between the operands: `"+"`, `"-"`, `"*"`
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

        # Adds or subtracts on the one numeric field two value objects share, answering a new
        # value object of `current`'s type.
        #
        # @param current [Runtime::Value] the attribute's pre-dispatch value
        # @param amount [Runtime::Value] how much to move by, coerced to the attribute's type
        # @param target [Symbol, String] name of the attribute, used only to word a refusal
        # @param sign [Integer] 1 to add, -1 to subtract
        # @param oper [String] `"increment"` or `"decrement"`, for refusal and fault wording
        # @return [Runtime::Value] a copy of `current` with the shared field replaced, rebuilt
        #   and re-validated through `Value#with`
        # @raise [Runtime::TypeMismatch] if the two do not share exactly one numeric field, or
        #   the rebuilt value object refuses the new field value
        # @raise [Runtime::InvariantViolation] if the new field value breaks one of the value
        #   object's own invariants
        # @raise [Bluebook::Expression::EvaluationError] if the result does not fit a signed
        #   64-bit Integer, or is a non-finite Float
        def arithmetic_value_object(current, amount, target, sign, oper)
          current_fields = current.to_h
          amount_fields  = amount.to_h
          # Widened from Integer to Numeric -- see #arithmetic's own
          # comment. A synthesised value-object wrapper around a bare
          # Float attribute (miette's Synapse#strength, auto-wrapped per
          # Part 3a's "bare primitives forbidden" finding) lands here as
          # a one-Float-field Value exactly the way a one-Integer-field
          # Value already did.
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

        # Looks up whether a mutation op adds or subtracts, from the generated `MUTATION_OPS` table.
        #
        # Not a bare `.find(...)&.sign || -1` — that would silently answer
        # decrement's sign for both an op this table has never heard of
        # and a declared, real op that simply carries no sign at all
        # (set/append/multiply/clamp/remove — see `MUTATION_OPS` above).
        # Callers today only ever reach this for :increment/:decrement
        # (both MutationApplier#apply and EntityInterpreter#
        # apply_to_element gate every other op through their own `case`
        # first, each with its own loud WiringError backstop), so this
        # raise is not a real runtime path yet — it is the same
        # backstop one level down, in case a future caller reaches
        # #sign_of directly for an op that was never meant to have one.
        #
        # @param oper [Symbol, String] the mutation op's name, such as `:increment`
        # @return [Integer] 1 for increment, -1 for decrement
        # @raise [Runtime::WiringError] if the op is unknown, or is declared with no sign
        #   (set, append, multiply, clamp, remove, delegate, corrects)
        def sign_of(oper)
          MUTATION_OPS.find { |candidate| candidate.name == oper.to_s }&.sign ||
            raise(WiringError, "no sign declared for mutation op #{oper.inspect} — add one before calling #sign_of")
        end

        # Scales an attribute's current value by `amount`, on a bare number or on the one numeric
        # field two value objects share.
        #
        # Vendored addition, not (yet) upstream hecks (migration plan
        # task 4, i106): `current * amount` -- the scaling counterpart to
        # increment/decrement's add/subtract. Same raw-vs-value-object
        # branch shape as #arithmetic/#arithmetic_value_object, reused
        # rather than duplicated verb-for-verb (a `Proc` picks the actual
        # arithmetic; everything else -- the Value unwrap/rewrap, the
        # TypeMismatch refusals -- is identical to the additive pair).
        #
        # @param current [Numeric, Runtime::Value, nil] the attribute's pre-dispatch value; nil
        #   (never set) counts as 0
        # @param amount [Numeric, Runtime::Value] the factor; a value object is combined field
        #   by field with a value-object `current`, and otherwise unwrapped to its single
        #   numeric field
        # @param target [Symbol, String] name of the attribute, used only to word a refusal
        # @return [Numeric, Runtime::Value] the product: a `Runtime::Value` when both sides are
        #   value objects, otherwise a bare number the caller re-wraps
        # @raise [Runtime::TypeMismatch] if `amount` or `current` is not numeric, or two value
        #   objects do not share exactly one numeric field
        # @raise [Runtime::InvariantViolation] if a value-object result breaks one of its own
        #   invariants
        # @raise [Bluebook::Expression::EvaluationError] if the product does not fit a signed
        #   64-bit Integer, or is a non-finite Float
        def multiply(current, amount, target)
          current ||= 0

          if current.is_a?(Value) && amount.is_a?(Value)
            return combine_value_object(current, amount, target, "multiply") do |c, a|
              bounded(c * a, "multiply", c, a, "*")
            end
          end

          # Same absent-`current`, VO-wrapped-`amount` gap as `#arithmetic`
          # — see that method's own comment.
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
        # Vendored addition, not (yet) upstream hecks (migration plan
        # task 4, i106): bound the current value into `[min, max]` -- no
        # "amount" to combine, so it does not go through
        # #arithmetic/#multiply's shared-numeric-field matching at all;
        # it clamps whichever single numeric field the wrapping value
        # object carries (a synthesised wrapper always carries exactly
        # one, per Part 3a's auto-synthesis).
        #
        # @param current [Numeric, Runtime::Value, nil] the attribute's pre-dispatch value; nil
        #   (never set) counts as 0
        # @param bounds [Array<Numeric>] the two-element `[min, max]` range to clamp into
        # @param target [Symbol, String] name of the attribute, used only to word a refusal
        # @return [Numeric, Runtime::Value] the clamped value: a `Runtime::Value` when
        #   `current` is one, otherwise a bare number the caller re-wraps
        # @raise [Runtime::TypeMismatch] if `current` is a value object with no single
        #   numeric field, or is neither numeric nor a value object
        def clamp(current, bounds, target)
          min, max = bounds
          # The same `current ||= 0` #arithmetic/#multiply both give a
          # phantom (never-set) numeric field, one line up from each —
          # this was the one arithmetic op that didn't, so a VO-typed
          # attribute with no declared `default:` (genuinely absent,
          # `Instance.defaults`/`#default_for`) hit TypeMismatch on the
          # first clamp. (#arithmetic/#multiply's own absent-current gap
          # is a real, separate bug: they do not silently treat an absent
          # field as zero; they raise too, blaming a perfectly valid
          # `amount` for not being an Integer when it is one, just still
          # Money-wrapped. Fixed alongside this one — see
          # #unwrap_single_numeric_field.)
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

        # `amount` arrives VO-wrapped whenever the command's own declared
        # attribute type says so (a real `Money`, not a bare Integer) —
        # true whether or not `current` has ever been set. Only meaningful
        # to call once `current` is known not to be a Value itself (the
        # `current.is_a?(Value) && amount.is_a?(Value)` branch, above in
        # both callers, already owns the case where both sides carry real
        # fields to combine). Refuses rather than guesses when more than
        # one field is numeric — genuinely ambiguous which one an absent
        # `current` should be treated as zero for, the same reasoning
        # `combine_value_object`'s own `shared_numeric.size == 1` check
        # already holds to when both sides are present.
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
