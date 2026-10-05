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
      # record that holds it. Shared nodes are immutable, so a caller cannot reach the journal
      # through a returned instance. Everything else in the state goes through `StateCodec`
      # whole. Both tables are weak and identity-keyed: a cache, never the only holder.
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
          lists = shareable_lists(state)
          return Ports::Persistence::StateCodec.copy(@aggregate, state) if lists.empty?

          copied = Ports::Persistence::StateCodec.copy(@aggregate, placeholders(state, lists))
          lists.each { |name, (attribute, elements)| copied[name] = journal_list(attribute, elements) }
          copied
        end

        # Hydrates journal-shaped state into the state a record holds.
        #
        # @param decoded [Hash] a fresh state in the shape `journal_state` returns; its non-shared
        #   values are hydrated in place of copies, so it must not be a journal entry's own state
        # @return [Hash{Symbol => Object}] hydrated state, defaults filled; the lists it shares
        #   are frozen arrays of frozen elements, and nothing mutable is shared with `decoded`
        def live_state(decoded)
          lists = shareable_lists(decoded)
          hydrated = Runtime::Instance.hydrate_with_defaults(@aggregate, placeholders(decoded, lists))
          lists.each { |name, (attribute, elements)| hydrated[name] = live_list(attribute, elements) }
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

        def composite_lists
          @composite_lists ||= @aggregate.attributes.each_with_object({}) do |attribute, found|
            next unless attribute.list? && !attribute.reference? && composite?(attribute)

            found[attribute.name.to_sym] = attribute
          end
        end

        def composite?(attribute)
          type = attribute.type.to_s
          !Runtime::Value.find_entity(@aggregate, type).nil? ||
            (@aggregate.respond_to?(:value_object) && !Runtime::Value.value_object_for(@aggregate, type).nil?)
        end

        # `state` with each shared list replaced by nil, which the codec leaves alone and
        # which holds the list's place in the key order.
        def placeholders(state, lists)
          return state if lists.empty?

          state.merge(lists.transform_values { nil })
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
