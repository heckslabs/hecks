require_relative "../../plain_english"

module Hecks
  module Projections
    module Glossary
      module Sentences
        # Speaks a dotted field path the way a reader names it. A one-field value object is
        # named by its own name, so `pizza.price_cents.cents` is "price" and
        # `customer_name.value` is "customer name".
        class Paths
          # @param holder [Bluebook::Aggregate, Bluebook::Entity] the construct the path starts on
          # @param value_objects [Array<Bluebook::ValueObject>] the value objects types resolve to
          def initialize(holder, value_objects)
            @holder = holder
            @by_name = value_objects.to_h { |value_object| [value_object.hecks_name, value_object] }
          end

          # @param path [String, Symbol] a dotted field path
          # @return [Boolean] whether it is the holder's lifecycle field
          def lifecycle?(path)
            lifecycle = @holder.respond_to?(:lifecycle) && @holder.lifecycle
            lifecycle ? lifecycle.field.to_s == path.to_s : false
          end

          # @param path [String, Symbol] a dotted field path
          # @return [String] how a reader names the field
          def label(path)
            hops = path.to_s.split("/")
            return hops.map { |hop| PlainEnglish.noun(hop) }.join("'s ") if hops.size > 1

            walk(path).first
          end

          # @param path [String, Symbol] a dotted field path
          # @return [String, nil] the type the path ends on, such as "String", when it resolves
          def type(path) = walk(path).last

          private

          # Follows each segment through the attributes and value objects it names. Inside a
          # one-field value object the label already said is kept.
          def walk(path)
            segments = path.to_s.split(".")
            state = { label: PlainEnglish.noun(segments.last), type: nil, attributes: @holder.attributes, named: false }
            segments.each do |segment|
              field = state[:attributes].find { |attribute| attribute.name.to_s == segment }
              return [state[:label], nil] unless field

              state = step(field, state)
            end
            [state[:label], leaf_type(state)]
          end

          # The primitive a path ends on: a value object compares by its one number, when it has
          # exactly one, as the query runtime does.
          def leaf_type(state)
            attributes = state[:attributes]
            return attributes.first.type.to_s if state[:named]

            numbers = attributes.select { |attribute| %w[Integer Float].include?(attribute.type.to_s) }
            numbers.one? ? numbers.first.type.to_s : state[:type]
          end

          # The state after one segment: its label, type, and where the next segment is looked up.
          def step(field, state)
            value_object = @by_name[field.type.to_s]
            label = state[:named] ? state[:label] : PlainEnglish.noun(field.name)
            single = value_object && value_object.attributes.size == 1
            label = PlainEnglish.noun(value_object.hecks_name) if single
            { label: label, type: field.type.to_s, attributes: value_object ? value_object.attributes : [],
              named: single || false }
          end
        end
      end
    end
  end
end
