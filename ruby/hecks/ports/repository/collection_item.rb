module Hecks
  module Persistence
    # Hecks::Persistence::CollectionItem
    #
    # A decorator (delegator) that wraps a single value object from a persisted
    # collection attribute. All method calls are forwarded to the underlying raw
    # object via +method_missing+, but the wrapper adds +delete+/+destroy+ methods
    # that remove the item from its parent CollectionProxy and persist the change.
    #
    # CollectionItem also overrides equality, hash, class, is_a?, frozen?, and
    # inspect so that it behaves transparently like the wrapped object in most
    # contexts (comparisons, logging, type checks).
    #
    # == Usage
    #
    #   pizza.toppings.first.name     # delegates to the underlying Topping value object
    #   pizza.toppings.first.delete   # removes from collection and persists the owner
    #   pizza.toppings.first.class    # => Topping (not CollectionItem)
    #
    class CollectionItem
        # Creates a new CollectionItem wrapping a raw value object.
        #
        # @param raw [Object] the underlying value object (e.g., a Topping instance)
        # @param collection [Hecks::Persistence::CollectionProxy] the parent collection
        #   that owns this item, used for deletion callbacks
        def initialize(raw, collection)
          @raw = raw
          @collection = collection
        end

        # Removes this item from its parent collection and persists the owner aggregate.
        #
        # @return [Object] the unwrapped raw value object that was removed
        def delete
          @collection.delete(self)
          @raw
        end
        alias destroy delete

        # Returns the unwrapped raw value object.
        # Used internally by CollectionProxy to compare items without wrapper interference.
        #
        # @return [Object] the underlying value object
        def __raw__
          @raw
        end

        # Compares this item with another for equality.
        # Unwraps CollectionItem instances before comparison so that wrapped and
        # unwrapped objects can be compared seamlessly.
        #
        # @param other [Object] the object to compare against
        # @return [Boolean] true if the underlying raw objects are equal
        def ==(other)
          if other.is_a?(CollectionItem)
            @raw == other.__raw__
          else
            @raw == other
          end
        end
        alias eql? ==

        # Returns the hash code of the underlying raw object.
        # Ensures CollectionItems can be used in Hash keys and Sets consistently
        # with their unwrapped counterparts.
        #
        # @return [Integer] the hash code of the raw object
        def hash
          @raw.hash
        end

        # Returns whether the underlying raw object is frozen.
        #
        # @return [Boolean] true if the raw object is frozen
        def frozen?
          @raw.frozen?
        end

        # Returns the class of the underlying raw object, not CollectionItem.
        # This makes the wrapper transparent for type inspection.
        #
        # @return [Class] the class of the raw object
        def class
          @raw.class
        end

        # Checks if the underlying raw object is an instance of the given class,
        # or falls back to the standard is_a? check on CollectionItem itself.
        #
        # @param klass [Class, Module] the class or module to check against
        # @return [Boolean] true if the raw object or CollectionItem is_a? klass
        def is_a?(klass)
          @raw.is_a?(klass) || super
        end

        # Returns the inspect string of the underlying raw object.
        #
        # @return [String] the inspect output of the raw object
        def inspect
          @raw.inspect
        end

        # Checks if the underlying raw object responds to the given method.
        # Used by Ruby to determine whether method_missing should be invoked.
        #
        # @param method [Symbol] the method name to check
        # @param include_private [Boolean] whether to include private methods
        # @return [Boolean] true if the raw object or CollectionItem responds to the method
        def respond_to_missing?(method, include_private = false)
          @raw.respond_to?(method, include_private) || super
        end

        # Delegates all unrecognized method calls to the underlying raw object.
        # This is the core of the transparent delegation pattern.
        #
        # @param method [Symbol] the method name being called
        # @param args [Array] positional arguments
        # @param block [Proc] optional block argument
        # @return [Object] the return value from the raw object's method
        # @raise [NoMethodError] if neither the raw object nor CollectionItem responds
        def method_missing(method, *args, &block)
          if @raw.respond_to?(method)
            @raw.send(method, *args, &block)
          else
            super
          end
        end
      end
  end
end
