require_relative "../../bluebook/expression/evaluator"
require_relative "../../rendering"
require_relative "../errors"
require_relative "../refusal_wording"
require_relative "invariant_violation"

module Hecksagain
  module Runtime
    class Value
      # The class-side engine: how a raw argument or stored field becomes a
      # typed Value. Extended into Value, so every method here reads as
      # `Value.for`, `Value.build`, … — `self` is the Value class.
      module Coercion
        def for(aggregate, name, value)
          attribute = aggregate.attribute(name)
          return value unless attribute

          for_attribute(aggregate, attribute, value)
        end

        def for_attribute(aggregate, attribute, value)
          return value if attribute.nil? || value.nil?
          return hydrate_entity_list(aggregate, attribute, value) if attribute.list?
          return value unless aggregate.respond_to?(:value_object)

          # THE SET THE ATTRIBUTE NAMES IS CHECKED WHERE THE ATTRIBUTE IS KNOWN.
          # `build` below sees only the value object, never which attribute asked
          # for it, so a command argument's `admits:` has to be read here — this
          # is the door every argument and every head field comes through.
          #
          # AFTER coercion, not before: a scalar arrives wrapped in whatever holder
          # its type names (`{value: "append"}` for an OpName), and checking the
          # raw payload would be checking the envelope.
          coerced = aggregate.value_object(attribute.type)
            .then do |value_object|
              if value.is_a?(self) && value.type_name == value_object&.hecks_name
                value
              elsif value_object
                build(value_object, fields_for(value_object, attribute.name, value))
              else
                value
              end
            end

          admit_declared_set(aggregate, attribute, coerced)
          coerced
        end

        def fields_for(value_object, name, value)
          return value.transform_keys(&:to_sym) if value.is_a?(Hash)
          # Mutations may legitimately carry a value object into a differently
          # named value-object slot with the same declared fields (for example,
          # PositiveMoney into an Account's Money balance).  Rebuild the target
          # type from its state; callers at the public boundary still have to
          # supply an object rather than a scalar.
          return value.to_h if value.is_a?(self)

          raise TypeMismatch,
                RefusalWording.render("TypeMismatch", "value_object_shape",
                                      name: name, type: value_object.hecks_name,
                                      offered: Rendering.describe(value))
        end

        def build(value_object, fields)
          fields = value_object.attributes.each_with_object(fields.transform_keys(&:to_sym)) do |attribute, completed|
            completed[attribute.name] = attribute.default unless completed.key?(attribute.name) || attribute.default.nil?
          end
          admit_member(value_object, fields)
          check_admitted(value_object, fields)
          check_numeric_fields(value_object, fields)
          check_patterns(value_object, fields)
          value_object.invariants.each do |invariant|
            next if Bluebook::Expression::Evaluator.call(invariant.canonical, fields)

            raise InvariantViolation,
                  "#{value_object.hecks_name} invariant violated — #{invariant.description} " \
                  "(given #{canonical_fields(fields)})"
          end
          new(value_object, fields)
        end

        def hydrate(aggregate, state)
          state.each_with_object({}) do |(name, value), hydrated|
            key       = name.to_sym
            attribute = aggregate.attribute(key)
            hydrated[key] = attribute ? for_attribute(aggregate, attribute, value) : value
          end
        end

        def hydrate_entity_list(aggregate, attribute, value)
          entity = aggregate.entities.find { |candidate| candidate.hecks_name == attribute.type.to_s }
          return value unless entity

          Array(value).map do |element|
            next element unless element.is_a?(Hash)

            element.each_with_object({}) do |(name, field_value), hydrated|
              key = name.to_sym
              field = entity.attribute(key)
              hydrated[key] = field ? for_attribute(aggregate, field, field_value) : field_value
            end
          end
        end

        # `Value.identifier` used to live here: hand it a one-field value object
        # and it opened it, so `identified_by :number` could pass for an identity
        # and the runtime would guess which field was meant. THAT GUESS IS GONE.
        # An identity names its field — `identified_by { number.value }` — and the
        # path is what reaches the scalar. A declaration that names no field is
        # refused when the bluebook loads, so nothing has to be unwrapped later.
        #
        # `scalar` below is a different job and stays: rendering a value object
        # into a column or a message, where there is no path to consult.

        # `Value.reference_id` lived here, opening a reference to find the id
        # inside it. A reference IS the id now — refused at the payload gate if it
        # arrives as anything else — so there is nothing left to open. The comment
        # it carried said retiring it meant changing how references are STORED ;
        # that is what happened.

        # A REFERENCE IS AN ID, SO AN OBJECT IS NOT ONE.
        #
        # Nothing coerces a reference — `for_attribute` misses on
        # "Reference<Account>", which is no value object's name, and hands the
        # argument straight through. That is why the wrapped form went in
        # unnoticed for as long as it did: there was no place it could be
        # refused, so whatever the first caller wrote became the shape.
        #
        # This is that place. It sits at the payload gate rather than inside
        # coercion because the sentence names the COMMAND, and `for_attribute`
        # never learns which command it is serving.
        #
        # An Array is deliberately not refused here. A reference is never a list
        # today, and inventing a rule for a shape the language cannot declare is
        # how decoration gets written.
        def refuse_object_reference(command, attribute, value)
          return unless attribute.reference?
          return unless value.is_a?(Hash) || value.is_a?(self)

          raise TypeMismatch,
                RefusalWording.render("TypeMismatch", "reference_as_object",
                                      command: command.hecks_name, attribute: attribute.name,
                                      known_by: known_by(attribute))
        end

        # "(Account is known by number)" — what to send instead. No article, on
        # purpose: "an Account" and "a Customer" differ by the target's first
        # letter, and a refusal pinned byte-for-byte should not hinge on an
        # article-choosing rule. Silent when the target is another chapter's,
        # where this runtime cannot see what it is known by.
        #
        # EVERY HEAD, because a caller has to pass every one. This read
        # `identified_by`, which is the SINGLE head and is nil the moment an
        # identity has two parts — so a composite target fell through the guard
        # and the refusal went silent exactly where it had the most to say. A
        # single-path target reads as it always did.
        def known_by(attribute)
          heads = Array(attribute.type.resolve&.identity_heads)
          return "" if heads.empty?

          " (#{attribute.type.target_name} is known by #{heads.join(', ')})"
        end

        def scalar(value)
          return value unless value.is_a?(self)

          fields = value.to_h
          return fields.values.first if fields.size == 1

          raise TypeMismatch, RefusalWording.render("TypeMismatch", "multi_field_scalar", type: value.type_name)
        end

        def from_identifier(aggregate, attribute, identifier)
          value_object = aggregate.value_object(attribute.type)
          return identifier unless value_object

          fields = value_object.attributes
          return build(value_object, { fields.first.name => identifier }) if fields.size == 1

          raise TypeMismatch, RefusalWording.render("TypeMismatch", "composite_identity", type: value_object.hecks_name)
        end

        def canonical_fields(fields)
          JSON.generate(fields.sort_by { |name, _| name.to_s }.to_h)
        end

        # A field declared Integer or Float must ARRIVE as one.
        #
        # Without this a String sails into a numeric field and the failure surfaces
        # later, inside a predicate, as `positive? expects a number, got "three"` —
        # an EvaluationError, which is NOT a domain refusal. So the runtime broke
        # where the domain should have said no, and the run contract recorded the
        # crash beside genuine refusals as though the domain had judged it.
        #
        # Checked BEFORE invariants, because an invariant reading a mistyped field
        # is exactly the thing that used to explode.
        NUMERIC = { "Integer" => Integer, "Float" => Numeric }.freeze
        private def check_numeric_fields(value_object, fields)
          value_object.attributes.each do |attribute|
            expected = NUMERIC[attribute.type.to_s]
            next unless expected

            given = fields[attribute.name]
            next if given.nil? || given.is_a?(expected)

            raise TypeMismatch,
                  RefusalWording.render("TypeMismatch", "numeric_field",
                                        type: value_object.hecks_name, field: attribute.name,
                                        expected: attribute.type, offered: Rendering.describe(given))
          end
        end

        # A field declared with a PATTERN must match it.
        #
        # Beside check_numeric_fields and for the same reason : a value that does
        # not look like what it claims to be is the DOMAIN saying no, and it should
        # say so here rather than let the wrong shape travel on and surface as a
        # broken predicate later.
        #
        # Which regexes may be written at all is PatternSubset's job, enforced when
        # the bluebook is declared — so by the time a value arrives here the pattern
        # is already a vetted, unambiguous one, and this is a plain match.
        private def check_patterns(value_object, fields)
          value_object.attributes.each do |attribute|
            pattern = attribute.pattern
            next unless pattern

            given = fields[attribute.name]
            next if given.nil?
            next if given.is_a?(String) && Regexp.new(pattern).match?(given)

            raise TypeMismatch,
                  RefusalWording.render("TypeMismatch", "pattern_mismatch",
                                        type: value_object.hecks_name, field: attribute.name,
                                        pattern: pattern, offered: Rendering.describe(given))
          end
        end
      end
    end
  end
end
