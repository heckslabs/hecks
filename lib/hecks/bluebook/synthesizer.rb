require_relative "attribute"

module Hecks
  module Bluebook
    # Synthesizes one argument per declared attribute from the IR: fixed markers for scalars,
    # a closed set's first member, and a known `created` id for references. Never random.
    module Synthesizer
      # Shared with `Attribute::PRIMITIVES` so the two lists cannot drift.
      PRIMITIVES = Attribute::PRIMITIVES

      # What a String field gets when `"smoke-test"` fails its pattern: a date, then a digit string,
      # fixed so the same pattern always gets the same value.
      PATTERN_CANDIDATES = %w[2026-01-01 1 a].freeze

      module_function

      # Synthesizes arguments for `command`. A reference whose target is not in `created`
      # gets a placeholder id.
      #
      # @param bluebook [Bluebook::Declaration] resolves value object type names to their shapes
      # @param aggregate [Bluebook::Aggregate] the aggregate `command` belongs to
      # @param command [Class] the `Bluebook::Command` subclass to synthesize arguments for
      # @param created [Hash{String => Object}] aggregate name mapped to an id minted earlier
      # @return [Hash{Symbol => Object}] one synthesized value per declared attribute
      def args_for(chapter, aggregate, command, created = {})
        command.attributes.to_h do |attribute|
          if attribute.reference?
            [attribute.name, created.fetch(attribute.target_name, "smoke-test-id")]
          else
            [attribute.name, value_for(chapter, aggregate, attribute.type)]
          end
        end
      end

      # Synthesizes a value object: its first member if a closed set, else one value per field.
      # Falls back to searching every aggregate, since a value object need not be local.
      #
      # @param bluebook [Bluebook::Declaration] the bluebook to search when
      #   `type_name` is not declared on `aggregate` itself
      # @param aggregate [Bluebook::Aggregate] the aggregate `type_name` is
      #   looked up on first
      # @param type_name [String] the value object's declared type name
      # @return [String, Hash{Symbol => Object}] the string `"smoke-test"` when
      #   no such value object is declared; otherwise a Hash of one value per
      #   field — the closed set's own first admitted member's fields, or one
      #   freshly synthesized scalar per declared field
      def value_for(chapter, aggregate, type_name)
        value_object = find_value_object(chapter, aggregate, type_name)
        return "smoke-test" unless value_object
        return value_object.members.first.to_h if populated_closed_set?(value_object)

        value_object.attributes.to_h { |field| [field.name, field_value(chapter, aggregate, field)] }
      end

      # A field's value, one that matches its pattern when a fixed candidate does.
      #
      # @param field [Bluebook::Attribute] the declared field
      # @return [Object] `field_value_for`'s value, or the first of `PATTERN_CANDIDATES` the
      #   field's pattern admits, when that value is a String the pattern refuses
      def field_value(chapter, aggregate, field)
        within_pattern(field.pattern, field_value_for(chapter, aggregate, field.type))
      end

      # @param pattern [String, nil] the field's regex source, if it declares one
      # @param value [Object] a synthesized value
      # @yieldreturn [Boolean] asked only of a value the pattern refuses: true keeps it as it is
      # @return [Object] `value`, or the first of `PATTERN_CANDIDATES` the pattern admits when
      #   `value` is a String it refuses and one fits
      def within_pattern(pattern, value, &keep)
        return value unless refused_by?(pattern, value)
        return value if keep&.call

        PATTERN_CANDIDATES.find { |candidate| pattern_admits?(pattern, candidate) } || value
      end

      # @return [Boolean] whether the value is a String the pattern, if any, does not admit
      def refused_by?(pattern, value) = value.is_a?(String) && !pattern.nil? && !pattern_admits?(pattern, value)

      # @return [Boolean] whether the regex source admits the text; false for a source Ruby rejects
      def pattern_admits?(source, text)
        Regexp.new(source).match?(text)
      rescue RegexpError
        false
      end

      # The value object `type_name` names, on `aggregate` first, then on any other aggregate.
      def find_value_object(chapter, aggregate, type_name)
        aggregate.value_object(type_name) ||
          chapter.aggregates.filter_map { |a| a.value_object(type_name) }.first
      end

      # Whether `value_object` is a closed set that admits at least one member.
      def populated_closed_set?(value_object)
        value_object.respond_to?(:closed_set?) && value_object.closed_set? && value_object.members.any?
      end

      # A field's value: a scalar for a primitive type, otherwise the nested value object.
      #
      # @param bluebook [Bluebook::Declaration] see `value_for`
      # @param aggregate [Bluebook::Aggregate] see `value_for`
      # @param type_name [String] the field's declared type name
      # @return [Integer, Float, true, false, String, Hash{Symbol => Object}] a
      #   bare scalar when `type_name` is a true primitive (see `scalar_for`),
      #   otherwise `value_for`'s own result for the nested value object it names
      def field_value_for(chapter, aggregate, type_name)
        PRIMITIVES.include?(type_name.to_s) ? scalar_for(type_name) : value_for(chapter, aggregate, type_name)
      end

      # A primitive's synthesized value; closed-set fields are handled by `value_for`.
      #
      # @param primitive [String, Symbol] the primitive type name, such as
      #   `"Integer"` or `"String"`
      # @return [Integer, Float, false, String] `0` for `"Integer"`, `0.0` for
      #   `"Float"`, `false` for `"TrueClass"`/`"FalseClass"`, or the string
      #   `"smoke-test"` for anything else
      def scalar_for(primitive)
        case primitive.to_s
        when "Integer" then 0
        when "Float" then 0.0
        when "TrueClass", "FalseClass" then false
        else "smoke-test"
        end
      end
    end
  end
end
