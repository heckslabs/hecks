require "objspace"
require_relative "../../../freezer"
require_relative "../../../ports/persistence/state_codec"
require_relative "../../../runtime/value"

module Hecks
  module Adapters
    class Memory
      # Lets a Memory save of a growing `list_of` copy and hydrate only the elements it has not
      # seen. A hydrated composite element is frozen, so its codec copy (the journal form) and
      # its hydrated form are each computed once, frozen, and shared by every journal entry and
      # record that holds it. A single value-object attribute that holds a list, directly or
      # through a nested value object, shares the same way: the hydrated `Runtime::Value` is
      # copied once, and a later version of it reuses the copies of the list elements it still
      # holds. Shared nodes are immutable, so a caller cannot reach the journal through a
      # returned instance. Everything else in the state goes through `StateCodec` whole. The
      # tables are weak and identity-keyed: a cache, never the only holder.
      class SharedElements
        # @param aggregate [Bluebook::Aggregate] the aggregate whose state this shares elements of
        def initialize(aggregate)
          @aggregate = aggregate
          reset!
        end

        # Forgets every remembered element.
        #
        # @return [SharedElements] self, now empty
        def reset!
          @journal = ObjectSpace::WeakMap.new   # live element => frozen decoded copy
          @live    = ObjectSpace::WeakMap.new   # frozen decoded copy => hydrated element
          @copies  = ObjectSpace::WeakMap.new   # frozen value-object copy this table built => true
          self
        end

        # Copies state into the shape the journal holds: `StateCodec.copy`, with every
        # shareable list element copied once and reused.
        #
        # @param state [Hash, nil] live state, such as `Instance#state`; nil for a delete entry
        # @return [Hash{Symbol => Object}, nil] the decoded copy; its shareable list elements
        #   are frozen and shared with every other copy that holds them, nothing else is shared
        #   with `state`
        def journal_state(state)
          lists  = shareable_lists(state)
          values = journal_values(state)
          return Ports::Persistence::StateCodec.copy(@aggregate, state) if lists.empty? && values.empty?

          copied = Ports::Persistence::StateCodec.copy(@aggregate, placeholders(state, lists, values))
          lists.each { |name, (attribute, elements)| copied[name] = journal_list(attribute, elements) }
          values.each { |name, (attribute, value)| copied[name] = journal_value(attribute, value) }
          copied
        end

        # Hydrates journal-shaped state into the state a record holds.
        #
        # @param decoded [Hash] a fresh state in the shape `journal_state` returns; its non-shared
        #   values are hydrated in place of copies, so it must not be a journal entry's own state
        # @return [Hash{Symbol => Object}] hydrated state, defaults filled; the lists and value
        #   objects it shares are frozen, and nothing mutable is shared with `decoded`
        def live_state(decoded)
          lists  = shareable_lists(decoded)
          values = live_values(decoded)
          hydrated = Runtime::Instance.hydrate_with_defaults(@aggregate, placeholders(decoded, lists, values))
          lists.each { |name, (attribute, elements)| hydrated[name] = live_list(attribute, elements) }
          values.each { |name, (attribute, copy)| hydrated[name] = live_value(attribute, copy) }
          hydrated
        end

        private

        # The list attributes of `state` whose elements can be shared: composite, not a
        # reference, and actually held as an Array.
        def shareable_lists(state)
          return {} unless state.is_a?(Hash)

          composite_lists.each_with_object({}) do |(name, attribute), found|
            elements = state[name]
            found[name] = [attribute, elements] if elements.is_a?(Array)
          end
        end

        def composite_lists = list_attributes(@aggregate)

        def list_attributes(owner)
          owner.attributes.each_with_object({}) do |attribute, found|
            next unless attribute.list? && !attribute.reference? && composite?(attribute)

            found[attribute.name.to_sym] = attribute
          end
        end

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

        def composite?(attribute)
          type = attribute.type.to_s
          !Runtime::Value.find_entity(@aggregate, type).nil? ||
            (@aggregate.respond_to?(:value_object) && !Runtime::Value.value_object_for(@aggregate, type).nil?)
        end

        # `state` with each shared list and value object replaced by nil, which the codec
        # leaves alone and which holds its place in the key order.
        def placeholders(state, lists, values)
          return state if lists.empty? && values.empty?

          state.merge(lists.merge(values).transform_values { nil })
        end

        # The frozen codec copy of one value object. A list it holds is rebuilt from the copies
        # of its elements, so a new version of the value costs the new elements, not all of them.
        def journal_value(attribute, value)
          known = @journal[value]
          return known if known

          fields = value.raw_fields
          lists  = value_lists(attribute, fields)
          held   = fields.merge(lists.transform_values { nil })
          copy   = Ports::Persistence::StateCodec.copy_list_element(@aggregate, attribute, held)
          copy.each_value { |inner| Freezer.deep(inner) }
          lists.each { |name, (list_attribute, elements)| copy[name] = journal_list(list_attribute, elements) }
          @copies[copy.freeze] = true
          @journal[value] = copy
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

        def journal_list(attribute, elements)
          elements.map { |element| journal_element(attribute, element) }.freeze
        end

        def journal_element(attribute, element)
          known = @journal[element]
          return known if known
          return element if @live.key?(element)

          copy = Ports::Persistence::StateCodec.copy_list_element(@aggregate, attribute, element)
          return copy unless immutable?(element)

          @journal[element] = Freezer.deep(copy)
        end

        def live_list(attribute, elements)
          elements.map { |element| live_element(attribute, element) }.freeze
        end

        def live_element(attribute, element)
          known = @live[element]
          return known if known

          live = Runtime::Value.trusting_stored_state do
            Runtime::Value.hydrate_entity_list(@aggregate, attribute, [element]).first
          end
          return live unless element.is_a?(Hash) && immutable?(element)

          @journal[live] = element
          @live[element] = live
        end

        def immutable?(element)
          case element
          when Runtime::Value then element.frozen?
          when Hash then Freezer.deeply_frozen?(element)
          else false
          end
        end
      end
    end
  end
end
