require_relative "../../../../freezer"
require_relative "../../../../ports/persistence/state_codec"
require_relative "../../../../runtime/value"

module Hecks
  module Adapters
    class Memory
      class SharedElements
        # The value-object half of element sharing: a single attribute holding one value object
        # that can hold a list is copied once, and a later version of it reuses the copies of the
        # list elements it still holds.
        module Values
          private

          # The attributes of the aggregate that hold one value object able to hold a list, by
          # name. A value object with no list in it is small and is left to the codec.
          def growable_values
            @growable_values ||= @aggregate.attributes.each_with_object({}) do |attribute, found|
              next if attribute.list? || attribute.reference?

              shape = value_object_of(attribute)
              found[attribute.name.to_sym] = attribute if shape && growable?(shape, [])
            end
          end

          def value_object_of(attribute)
            return nil unless @aggregate.respond_to?(:value_object)

            Runtime::Value.value_object_for(@aggregate, attribute.type.to_s)
          end

          def growable?(shape, seen)
            return false if seen.include?(shape)

            shape.attributes.any? do |attribute|
              next false if attribute.reference?
              next true if attribute.list?

              nested = value_object_of(attribute)
              nested ? growable?(nested, seen + [shape]) : false
            end
          end

          # The growable value-object attributes of `state` holding a frozen value of their type.
          def journal_values(state)
            return {} unless state.is_a?(Hash)

            growable_values.each_with_object({}) do |(name, attribute), found|
              value = state[name]
              found[name] = [attribute, value] if value.is_a?(Runtime::Value) && sharable_value?(attribute, value)
            end
          end

          def sharable_value?(attribute, value)
            value.frozen? && value.type_name == value_object_of(attribute).hecks_name
          end

          # The growable value-object attributes of `decoded` holding a frozen Hash: a copy this
          # table made, or one a caller froze.
          def live_values(decoded)
            return {} unless decoded.is_a?(Hash)

            growable_values.each_with_object({}) do |(name, attribute), found|
              copy = decoded[name]
              found[name] = [attribute, copy] if copy.is_a?(Hash) && copy.frozen?
            end
          end

          # The frozen codec copy of one value object. A list it holds is rebuilt from the copies
          # of its elements, so a new version of the value costs the new elements, not all of them.
          def journal_value(attribute, value)
            known = @journal[value]
            return known if known

            copy = build_value_copy(attribute, value)
            @copies[copy.freeze] = true
            @journal[value] = copy
          end

          def build_value_copy(attribute, value)
            fields = value.raw_fields
            lists  = value_lists(attribute, fields)
            held   = fields.merge(lists.transform_values { nil })
            copy   = Ports::Persistence::StateCodec.copy_list_element(@aggregate, attribute, held)
            copy.each_value { |inner| Freezer.deep(inner) }
            lists.each { |name, (list_attribute, elements)| copy[name] = journal_list(list_attribute, elements) }
            copy
          end

          def value_lists(attribute, fields)
            list_attributes(value_object_of(attribute)).each_with_object({}) do |(name, list_attribute), found|
              elements = fields[name]
              found[name] = [list_attribute, elements] if elements.is_a?(Array)
            end
          end

          # The hydrated value for one frozen copy, its lists rebuilt from the hydrated elements
          # already held.
          def live_value(attribute, copy)
            known = @live[copy]
            return known if known

            lists  = value_lists(attribute, copy)
            fields = copy.merge(lists.to_h { |name, (list_attribute, elements)| [name, live_list(list_attribute, elements)] })
            live   = Runtime::Value.trusting_stored_state do
              Runtime::Value.for_attribute(@aggregate, attribute, fields)
            end
            return live unless @copies.key?(copy)

            @journal[live] = copy
            @live[copy] = live
          end
        end
      end
    end
  end
end
