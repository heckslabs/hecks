require_relative "../../rendering"
require_relative "../errors"
require_relative "../refusal_wording"
require_relative "../value"

module Hecksagain
  module Runtime
    class CommandRules
      # The arithmetic half of mutation: what a source resolves to, and how
      # increment/decrement land on an Integer or a one-numeric-field value
      # object.
      module Arithmetic
        # The ops Runtime::CommandInterpreter applies. Declared the same way in
        # Vocabulary::MutationOp (language/bluebook/vocabulary.bluebook) —
        # spec/vocabulary_conformance_spec holds the two tables equal, so
        # increment/decrement's sign cannot drift from what the language says
        # each op means. set/append carry no sign — they do no arithmetic.
        MutationOp = Struct.new(:name, :sign, keyword_init: true)

        MUTATION_OPS = [
          MutationOp.new(name: "set",       sign: nil),
          MutationOp.new(name: "append",    sign: nil),
          MutationOp.new(name: "increment", sign: 1),
          MutationOp.new(name: "decrement", sign: -1),
          # Vendored addition, not (yet) upstream hecksagain (migration
          # plan task 4, i106): multiply/clamp carry no sign -- like
          # set/append, they do no add-or-subtract arithmetic (multiply
          # scales, clamp bounds). See #multiply/#clamp below.
          MutationOp.new(name: "multiply",  sign: nil),
          MutationOp.new(name: "clamp",     sign: nil),
          # Vendored addition, not (yet) upstream hecksagain (migration
          # plan task 4): remove -- carries no sign, like set/append; it
          # matches a list element by value rather than doing arithmetic.
          # Declared here so this table stays exactly what
          # Vocabulary::MutationOp declares (spec/vocabulary_conformance_spec
          # holds the two equal) -- MutationApplier's own `when :remove`
          # branch (mutation_applier.rb) never calls #sign_of, so this was
          # a declared-vocabulary gap, not a behaviour gap.
          MutationOp.new(name: "remove",    sign: nil)
        ].freeze

        # A mutation's source is either the NAME OF AN ARGUMENT or a LITERAL, and
        # the two are told apart by type : a Symbol is always a name, a String or a
        # number is always a value. Checked across all eight chapters — `to: :name`
        # and `to: "sold"`, never a Symbol meant as a value.
        #
        # `&& args.key?(source)` used to guard the lookup, and that guard is what
        # made an ABSENT argument fall through to `source` and return THE SYMBOL
        # ITSELF as the value. `Customer.Register` without its `name` set name to
        # the literal `:name`, coercion met a Symbol where a PersonName belonged,
        # and the refusal read "name is a PersonName — pass its fields as an
        # object, not :name" — a message describing a mistake the caller had not
        # made. The real mistake, an absent argument, was never the one refused,
        # which is what fuzz surfaced.
        #
        # Absent now resolves to nil. Whether it should be REFUSED instead
        # is a separate question — the language cannot yet say which arguments are
        # optional, and the meta-domain has plenty that are.
        def resolve_source(source, args)
          return args[source] if source.is_a?(Symbol)

          source
        end

        def arithmetic(current, amount, target, sign)
          op = sign.positive? ? "increment" : "decrement"
          current ||= 0

          if current.is_a?(Value) && amount.is_a?(Value)
            return arithmetic_value_object(current, amount, target, sign, op)
          end

          # Widened from Integer to Numeric (migration plan task 4, i106):
          # miette's organ math increments a Float (`increment: 0.02`) --
          # the raw, non-value-object path only ever mattered for Integer
          # counters before this corpus existed. Integer stays the common
          # case; Float is now accepted the same way.
          unless amount.is_a?(Numeric)
            raise TypeMismatch, RefusalWording.render("TypeMismatch", "arithmetic_amount",
                                                      op: op, target: target, offered: Rendering.describe(amount))
          end
          unless current.is_a?(Numeric)
            raise TypeMismatch, RefusalWording.render("TypeMismatch", "arithmetic_current",
                                                      op: op, target: target, offered: Rendering.describe(current))
          end

          current + (sign * amount)
        end

        def arithmetic_value_object(current, amount, target, sign, op)
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
                  RefusalWording.render("TypeMismatch", "arithmetic_shared_field", op: op, target: target)
          end

          field = shared_numeric.first
          current.with(field, current[field] + (sign * amount[field]))
        end

        # Not a bare `.find(...)&.sign || -1` — that silently answered
        # DECREMENT'S sign for BOTH an op this table has never heard of
        # AND a declared, real op that simply carries no sign at all
        # (set/append/multiply/clamp/remove — see MUTATION_OPS above).
        # Callers today only ever reach this for :increment/:decrement
        # (both MutationApplier#apply and EntityInterpreter#
        # apply_to_element gate every other op through their own `case`
        # first, each with its own loud WiringError backstop), so this
        # raise is not a real runtime path yet — it is the same
        # backstop one level down, in case a future caller reaches
        # #sign_of directly for an op that was never meant to have one.
        def sign_of(op)
          MUTATION_OPS.find { |candidate| candidate.name == op.to_s }&.sign ||
            raise(WiringError, "no sign declared for mutation op #{op.inspect} — add one before calling #sign_of")
        end

        # Vendored addition, not (yet) upstream hecksagain (migration plan
        # task 4, i106): `current * amount` -- the scaling counterpart to
        # increment/decrement's add/subtract. Same raw-vs-value-object
        # branch shape as #arithmetic/#arithmetic_value_object, reused
        # rather than duplicated verb-for-verb (a `Proc` picks the actual
        # arithmetic; everything else -- the Value unwrap/rewrap, the
        # TypeMismatch refusals -- is identical to the additive pair).
        def multiply(current, amount, target)
          current ||= 0

          if current.is_a?(Value) && amount.is_a?(Value)
            return combine_value_object(current, amount, target, "multiply") { |c, a| c * a }
          end

          unless amount.is_a?(Numeric) && current.is_a?(Numeric)
            raise TypeMismatch, RefusalWording.render("TypeMismatch", "arithmetic_amount",
                                                      op: "multiply", target: target,
                                                      offered: Rendering.describe(current.is_a?(Numeric) ? amount : current))
          end

          current * amount
        end

        # Vendored addition, not (yet) upstream hecksagain (migration plan
        # task 4, i106): bound the CURRENT value into `[min, max]` -- no
        # "amount" to combine, so it does not go through
        # #arithmetic/#multiply's shared-numeric-field matching at all;
        # it clamps whichever single numeric field the wrapping value
        # object carries (a synthesised wrapper always carries exactly
        # one, per Part 3a's auto-synthesis).
        def clamp(current, bounds, target)
          min, max = bounds
          # THE SAME `current ||= 0` #arithmetic/#multiply both give a
          # PHANTOM (never-set) numeric field, one line up from each —
          # this was the one arithmetic op that didn't, so a VO-typed
          # attribute with no declared `default:` (genuinely absent,
          # `Instance.defaults`/`#default_for`) hit TypeMismatch on the
          # FIRST clamp, where increment/decrement/multiply would have
          # silently treated the same absent field as zero.
          current ||= 0
          if current.is_a?(Value)
            fields = current.to_h
            field  = fields.keys.find { |f| fields[f].is_a?(Numeric) } or
              raise TypeMismatch, RefusalWording.render("TypeMismatch", "arithmetic_current",
                                                        op: "clamp", target: target, offered: Rendering.describe(current))
            return current.with(field, fields[field].clamp(min, max))
          end

          unless current.is_a?(Numeric)
            raise TypeMismatch, RefusalWording.render("TypeMismatch", "arithmetic_current",
                                                      op: "clamp", target: target, offered: Rendering.describe(current))
          end

          current.clamp(min, max)
        end

        private

        def combine_value_object(current, amount, target, op)
          current_fields = current.to_h
          amount_fields  = amount.to_h
          shared_numeric = current_fields.keys.select do |field|
            current_fields[field].is_a?(Numeric) && amount_fields[field].is_a?(Numeric)
          end
          unless shared_numeric.size == 1
            raise TypeMismatch,
                  RefusalWording.render("TypeMismatch", "arithmetic_shared_field", op: op, target: target)
          end

          field = shared_numeric.first
          current.with(field, yield(current[field], amount[field]))
        end
      end
    end
  end
end
