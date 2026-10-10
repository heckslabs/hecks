require_relative "../../bluebook/expression/evaluator"
require_relative "../errors"
require_relative "../refusal_wording"
require_relative "invariant_violation"

module Hecks
  module Runtime
    class Value
      # What a value object's own fields pass through on construction: defaults, nested
      # normalization, and the full set of boundary checks and invariants. Extended into `Value`
      # beside `Coercion`.
      module Validation
        # `build`'s own recursive twin of `for_attribute`, normalizing a value
        # object's own composite-typed fields into their declared shape.
        #
        # Stays a plain Hash, never a nested `Value` — `Value#with` depends on that.
        #
        # @param aggregate [Bluebook::Aggregate, Entity, nil] nested-type lookup scope
        # @param value_object [Class] the value object `fields` belongs to
        # @param fields [Hash{Symbol => Object}] the outer fields, already defaulted
        # @return [Hash{Symbol => Object}] `fields` with composite fields normalized
        # @raise [Runtime::TypeMismatch] if a nested field cannot be coerced
        # @raise [Runtime::UnknownArgument] if a nested field names an undeclared key
        # @raise [Runtime::InvariantViolation] if a nested field breaks its own invariant
        def normalize_composite_fields(aggregate, value_object, fields)
          return fields unless aggregate.respond_to?(:value_object)

          value_object.attributes.each do |attribute|
            next unless fields.key?(attribute.name)

            normalize_composite_field(aggregate, attribute, fields)
          end

          fields
        end

        # Fills every declared attribute `fields` lacks with its own `default:`, and every required
        # list it lacks with an empty one: a list left out reads as no members, the one shape the
        # Rust runtime (a `Vec`) can hold, so a value object built from nothing (a required
        # argument left empty, C3.7) is `{blocks: []}` on both sides rather than `{}` here.
        # An optional list stays absent, and an offered list, empty or not, is kept as offered.
        #
        # @param value_object [Class] the `Bluebook::ValueObject` subclass whose
        #   declared defaults are read
        # @param fields [Hash{Symbol => Object}] the offered fields; written in place
        # @return [Hash{Symbol => Object}] `fields`, with defaults filled in
        def apply_defaults(value_object, fields)
          value_object.attributes.each_with_object(fields) do |attribute, completed|
            fill_absent(completed, attribute) unless completed.key?(attribute.name)
          end
        end

        # The full entry point a value object's own fields pass through — shared by
        # `build` and `normalize_composite_fields`, so a nested field refuses
        # exactly like the same type declared directly on a command.
        #
        # @param value_object [Class] the `Bluebook::ValueObject` subclass to
        #   validate `fields` against
        # @param fields [Hash{Symbol => Object}] already-defaulted, nested-normalized fields
        # @return [void]
        # @raise [Runtime::UnknownArgument] if `fields` names an undeclared key
        # @raise [Runtime::TypeMismatch] if a required field is missing or wrong-shaped
        # @raise [Runtime::InvariantViolation] if `fields` breaks a declared invariant
        def validate!(value_object, fields)
          # C6.3 — a value object validates on construction from input only; state
          # read back from the store is trusted as written, so tightening an
          # invariant never makes an old record unreadable. `hydrate` sets this flag.
          return if trusting_stored_state?

          check_unknown_fields(value_object, fields)
          check_required_fields(value_object, fields)
          admit_member(value_object, fields)
          check_admitted(value_object, fields)
          check_list_shapes(value_object, fields)
          check_numeric_fields(value_object, fields)
          check_scalar_shapes(value_object, fields)
          check_patterns(value_object, fields)
          check_invariants(value_object, fields)
        end

        # Renders a value object's fields as a canonical JSON string, for an
        # invariant refusal to quote.
        #
        # @param fields [Hash{Symbol, String => Object}] the field values to render
        # @return [String] `fields`, sorted by key name and JSON-encoded
        def canonical_fields(fields)
          JSON.generate(fields.sort_by { |name, _| name.to_s }.to_h)
        end

        private

        # The default an absent attribute declares, else an empty list for a required list.
        def fill_absent(fields, attribute)
          return fields[attribute.name] = attribute.default unless attribute.default.nil?

          fields[attribute.name] = [] if attribute.list? && !attribute.optional?
        end

        def normalize_composite_field(aggregate, attribute, fields)
          # A list member hydrates the same as a top-level list, so a value
          # read back from the store matches the shape a live dispatch wrote.
          # An input list member is validated as offered and left as offered.
          return normalize_list(aggregate, attribute, fields) if attribute.list?

          raw = fields[attribute.name]
          return if raw.nil? || raw.is_a?(self)

          nested = value_object_for(aggregate, attribute.type)
          return unless nested

          nested_fields = apply_defaults(nested, fields_for(nested, attribute.name, raw))
          nested_fields = normalize_composite_fields(aggregate, nested, nested_fields)
          validate!(nested, nested_fields)
          fields[attribute.name] = nested_fields
        end

        def normalize_list(aggregate, attribute, fields)
          return hydrate_stored_list(aggregate, attribute, fields) if trusting_stored_state?

          validate_input_list(aggregate, attribute, fields)
        end

        # Runs each value-object member of an input list through the same entry point a nested
        # single
        # value goes through, so a member's own invariants and nested lists refuse on dispatch
        # exactly as they do when the list sits directly on a command. The members stay as offered.
        def validate_input_list(aggregate, attribute, fields)
          nested = value_object_for(aggregate, attribute.type)
          return unless nested

          Array(fields[attribute.name]).each do |member|
            next unless member.is_a?(Hash)

            member_fields = apply_defaults(nested, fields_for(nested, attribute.name, member))
            validate!(nested, normalize_composite_fields(aggregate, nested, member_fields))
          end
        end

        def hydrate_stored_list(aggregate, attribute, fields)
          return unless trusting_stored_state?

          fields[attribute.name] = for_attribute(aggregate, attribute, fields[attribute.name])
        end

        # An optional attribute the caller left out reads as nil in an invariant, so a rule can
        # ask `x.nil?` or `x.set?` of it instead of failing to resolve a key that was never sent.
        def with_absent_optionals(value_object, fields)
          absent = value_object.attributes.select { |attribute| attribute.optional? && !fields.key?(attribute.name) }
          return fields if absent.empty?

          absent.to_h { |attribute| [attribute.name, nil] }.merge(fields)
        end

        def check_invariants(value_object, fields)
          known = with_absent_optionals(value_object, fields)
          value_object.invariants.each do |invariant|
            next if Bluebook::Expression::Evaluator.call_rule(invariant, known)

            raise InvariantViolation,
                  RefusalWording.render_site("InvariantViolation", "value_object_invariant",
                                             name: value_object.hecks_name, description: invariant.description,
                                             offered: canonical_fields(fields))
          end
        end
      end
    end
  end
end
