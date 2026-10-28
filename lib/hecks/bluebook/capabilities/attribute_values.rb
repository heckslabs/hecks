module Hecks
  module Bluebook
    module Capabilities
      # Reads the value a capability entry names ("Aggregate.attribute"): whole seconds, text,
      # or the attribute's own name. Extended onto {Capabilities}, whose singleton methods
      # these become.
      module AttributeValues
        # The whole seconds a duration attribute's `default:` holds: a bare integer, or the
        # `{ value: N }` fill of a one-field value object (how a bluebook types a number).
        #
        # @param default [Object] an attribute's `default:`
        # @return [Integer, nil] the positive whole seconds, or `nil` when it is not that
        def duration_seconds(default)
          seconds = filled_value(default)
          seconds if seconds.is_a?(Integer) && seconds.positive?
        end

        # The seconds a `:duration` verb ("Aggregate.attribute") resolves to in `bluebook`.
        #
        # @param bluebook [Bluebook::Declaration] the bluebook that declares the aggregate
        # @param verb [String] the entry, spelled "Aggregate.attribute"
        # @return [Integer, nil] the positive whole seconds, or `nil` when the verb names no such
        #   attribute or its default is not whole seconds
        def duration_of(declaration, verb)
          duration_seconds(attribute_default(declaration, verb))
        end

        # The `default:` of the attribute a verb ("Aggregate.attribute") names in `bluebook`.
        #
        # @param bluebook [Bluebook::Declaration] the bluebook that declares the aggregate
        # @param verb [String] the entry, spelled "Aggregate.attribute"
        # @return [Object, nil] that attribute's `default:`, or `nil` when there is none
        def attribute_default(declaration, verb)
          aggregate_name, attribute_name = verb.split(".", 2)
          aggregate = declaration.aggregate(aggregate_name)
          aggregate&.attributes&.find { |a| a.name.to_s == attribute_name }&.default
        end

        # A default's value: the bare value, or the `{ value: x }` fill of a one-field value object.
        #
        # @param default [Object] an attribute's `default:`
        # @return [Object] the bare value
        def filled_value(default)
          default.is_a?(Hash) ? default.fetch(:value) { default["value"] } : default
        end

        # The string a `:text` verb ("Aggregate.attribute") resolves to in `bluebook`: the
        # attribute's `default:`, bare or as the `{ value: "..." }` fill of a one-field value
        # object (ADR 0099).
        #
        # @param bluebook [Bluebook::Declaration] the bluebook that declares the aggregate
        # @param verb [String] the entry, spelled "Aggregate.attribute"
        # @return [String, nil] the non-empty text, or `nil` when the verb names no such attribute
        #   or its default is not text
        def text_of(declaration, verb)
          text = filled_value(attribute_default(declaration, verb))
          text if text.is_a?(String) && !text.empty?
        end

        # The attribute name an `:attribute` verb ("Aggregate.attribute") resolves to in `bluebook`.
        #
        # @param bluebook [Bluebook::Declaration] the bluebook that declares the aggregate
        # @param verb [String] the entry, spelled "Aggregate.attribute"
        # @return [String, nil] the attribute's name, or `nil` when the aggregate lacks it
        def attribute_of(declaration, verb)
          aggregate_name, attribute_name = verb.split(".", 2)
          found = declaration.aggregate(aggregate_name)&.attributes&.any? { |a| a.name.to_s == attribute_name }
          attribute_name if found
        end
      end
    end
  end
end
