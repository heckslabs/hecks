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
          MutationOp.new(name: "decrement", sign: -1)
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
          op      = sign.positive? ? "increment" : "decrement"
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

        def sign_of(op) = MUTATION_OPS.find { |candidate| candidate.name == op.to_s }&.sign || -1
      end
    end
  end
end
