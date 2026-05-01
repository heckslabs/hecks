Hecks::Chapters.load_aggregates(
  Hecks::Runtime::PortInternals,
  base_dir: __dir__
)

module Hecks
  module Persistence
    # Hecks::Persistence::CollectionProxy
    #
    # Wraps a list attribute on an aggregate, providing create/delete/count
    # methods that rebuild the aggregate with the modified collection and
    # save it back to the repo.
    #
    # Behaves like an Array for reading (each, map, size, etc.) but adds
    # persistence-aware mutations. Items are wrapped in CollectionItem so
    # they support .delete directly.
    #
    # == Persistence model
    #
    # When a mutation occurs (create, delete, clear), the proxy:
    # 1. Builds a new items array with the change applied
    # 2. Reconstructs the owner aggregate with the updated collection
    # 3. Saves the new owner to the repository
    # 4. Updates the local items reference to reflect the change
    #
    # This follows the immutable aggregate pattern -- aggregates are rebuilt
    # rather than mutated in place.
    #
    # == Usage
    #
    #   pizza = Pizza.create(name: "Margherita")
    #   pizza.toppings.create(name: "Mozzarella", amount: 2)
    #   pizza.toppings.count          # => 1
    #   pizza.toppings.first.delete   # removes and persists
    #   pizza.toppings.empty?         # => true
    #
    class CollectionProxy
        include Enumerable

        # Wraps a list attribute with persistence-aware mutation methods.
        #
        # @param items [Array] the current items in the collection (raw value objects)
        # @param owner [Object] the aggregate instance that owns this collection
        # @param attr_name [Symbol] the name of the list attribute on the owner (e.g., :toppings)
        # @param value_object_class [Class] the class used to instantiate new items (e.g., Topping)
        # @param repo [Object] the repository adapter for persisting the owner after mutations
        def initialize(items:, owner:, attr_name:, value_object_class:, repo:)
          @items = items || []
          @owner = owner
          @attr_name = attr_name
          @value_object_class = value_object_class
          @repo = repo
        end

        # Creates a new item, appends it to the collection, and persists the owner.
        #
        # Instantiates a new value object from the given attributes, appends it to
        # the collection, rebuilds the owner aggregate, and saves it to the repository.
        #
        # @param attrs [Hash] keyword arguments passed to the value object constructor
        # @return [Hecks::Persistence::CollectionItem] the newly created item wrapped
        #   in a CollectionItem for delete support
        def create(**attrs)
          item = @value_object_class.new(**attrs)
          new_items = @items + [item]
          rebuild_owner(new_items)
          wrap(item)
        end

        # Removes the first matching item from the collection and persists the owner.
        #
        # If the item is a CollectionItem, unwraps it first. Only removes the first
        # occurrence that matches by equality, leaving duplicates intact.
        #
        # @param item [Object, Hecks::Persistence::CollectionItem] the item to remove
        # @return [Object] the item that was passed in (unchanged)
        def delete(item)
          raw = item.respond_to?(:__raw__) ? item.__raw__ : item
          found = false
          new_items = @items.reject { |item| !found && item == raw && (found = true) }
          rebuild_owner(new_items)
          item
        end

        # Removes all items from the collection and persists the owner.
        #
        # @return [Hecks::Persistence::CollectionProxy] self, now empty
        def clear
          rebuild_owner([])
          self
        end

        # Yields each item wrapped in a CollectionItem.
        # Required by Enumerable to support map, select, reject, etc.
        #
        # @yield [Hecks::Persistence::CollectionItem] each item in the collection
        # @return [void]
        def each(&block)
          @items.each { |item| block.call(wrap(item)) }
        end

        # Returns the number of items in the collection.
        #
        # @return [Integer] the count of items
        def size
          @items.size
        end
        alias count size
        alias length size

        # Returns true if the collection has no items.
        #
        # @return [Boolean] true when the collection is empty
        def empty?
          @items.empty?
        end

        # Returns true if any item matches the optional block condition.
        # Without a block, returns true if any items exist.
        #
        # @yield [Object] optional block to test each raw item
        # @return [Boolean] true if any item matches
        def any?(&block)
          block ? @items.any?(&block) : @items.any?
        end

        # Returns the first item wrapped in a CollectionItem, or nil if empty.
        #
        # @return [Hecks::Persistence::CollectionItem, nil] the first item or nil
        def first
          item = @items.first
          item ? wrap(item) : nil
        end

        # Returns the last item wrapped in a CollectionItem, or nil if empty.
        #
        # @return [Hecks::Persistence::CollectionItem, nil] the last item or nil
        def last
          item = @items.last
          item ? wrap(item) : nil
        end

        # Returns the item at the given index wrapped in a CollectionItem, or nil.
        #
        # @param index [Integer] the zero-based index into the collection
        # @return [Hecks::Persistence::CollectionItem, nil] the item at the index or nil
        def [](index)
          item = @items[index]
          item ? wrap(item) : nil
        end

        # Returns all items as an Array of CollectionItem wrappers.
        #
        # @return [Array<Hecks::Persistence::CollectionItem>] all items wrapped
        def to_a
          @items.map { |item| wrap(item) }
        end

        # Concatenates the raw items with another array.
        # Does not persist -- returns a plain Array.
        #
        # @param other [Array] the array to concatenate with
        # @return [Array] a new array combining items from both
        def +(other)
          @items + Array(other)
        end

        # Returns a string representation of the underlying items array.
        #
        # @return [String] the inspect output of the raw items
        def inspect
          @items.inspect
        end

        private

        # Wraps a raw value object in a CollectionItem for delete support.
        #
        # @param item [Object] the raw value object to wrap
        # @return [Hecks::Persistence::CollectionItem] the wrapped item
        def wrap(item)
          CollectionItem.new(item, self)
        end

        # Rebuilds the owner aggregate with an updated collection and persists it.
        #
        # Reconstructs the owner by reading all current attribute values and
        # substituting the collection attribute with the new items. Creates a new
        # aggregate instance (immutable pattern), preserves timestamps, saves to
        # the repository, and updates the local state.
        #
        # @param new_items [Array] the new set of items for the collection attribute
        # @return [Object] the newly constructed owner aggregate instance
        def rebuild_owner(new_items)
          attrs = { id: @owner.id }
          if @owner.class.respond_to?(:hecks_attributes)
            @owner.class.hecks_attributes.each do |hattr|
              attrs[hattr.name] = hattr.name == @attr_name ? new_items : @owner.send(hattr.name)
            end
          else
            @owner.class.instance_method(:initialize).parameters.each do |_param_type, name|
              next unless name
              if name == @attr_name
                attrs[name] = new_items
              elsif name != :id && @owner.respond_to?(name)
                attrs[name] = @owner.send(name)
              end
            end
          end

          new_owner = @owner.class.new(**attrs)
          new_owner.instance_variable_set(:@created_at, @owner.created_at) if @owner.respond_to?(:created_at)
          @repo.save(new_owner)

          @items = new_items.freeze
          @owner.instance_variable_set(:"@#{@attr_name}", new_items.freeze)

          new_owner
        end
      end
  end
end
