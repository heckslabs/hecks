module Hecks
  module Persistence
    # Hecks::Persistence::RepositoryMethods
    #
    # Adds CRUD persistence methods to aggregate classes. Bound automatically
    # by +Persistence.bind+ during application boot. Uses +hecks_attributes+
    # metadata for introspection when available, falling back to constructor
    # parameter reflection.
    #
    # == Class methods added
    #
    # - +.find(id)+ -- looks up an aggregate by ID
    # - +.all+ -- returns all persisted aggregates
    # - +.count+ -- returns the total number of persisted aggregates
    # - +.delete(id)+ -- removes an aggregate by ID
    # - +.first+ / +.last+ -- convenience accessors
    # - +.create(**attrs)+ -- instantiates, stamps, saves, and returns a new aggregate
    #
    # == Instance methods added
    #
    # - +#save+ -- persists the current aggregate to the repository
    # - +#update(**attrs)+ -- rebuilds the aggregate with new attributes and persists
    # - +#destroy+ -- removes the aggregate from the repository
    # - +#destroyed?+ -- returns true if +destroy+ has been called
    #
    # == Usage
    #
    #   Pizza.find(id) / Pizza.all / Pizza.count
    #   Pizza.create(name: "Margherita")
    #   pizza.save / pizza.update(name: "New") / pizza.destroy
    #
    module RepositoryMethods
      # Binds CRUD class and instance methods onto the given aggregate class.
      #
      # Stores a reference to the repository on the class and delegates to
      # the private helpers that define individual methods.
      #
      # @param klass [Class] the aggregate class to augment (e.g., Pizza)
      # @param repo [Object] the repository adapter instance that handles
      #   save, find, delete, all, and count operations
      # @return [void]
      def self.bind(klass, repo)
        klass.instance_variable_set(:@__hecks_repo__, repo)
        bind_class_methods(klass, repo)
        bind_instance_methods(klass, repo)
      end

      # Defines class-level CRUD methods on the aggregate class.
      #
      # @param klass [Class] the aggregate class to augment
      # @param repo [Object] the repository adapter instance
      # @return [void]
      def self.bind_class_methods(klass, repo)
        klass.define_singleton_method(:find) { |id| repo.find(id) }
        klass.define_singleton_method(:all) { repo.all }
        klass.define_singleton_method(:count) { repo.count }
        klass.define_singleton_method(:delete) { |id| repo.delete(id) }
        klass.define_singleton_method(:first) { all.first }
        klass.define_singleton_method(:last) { all.last }

        klass.define_singleton_method(:create) do |**attrs|
          constructor_attrs = {}
          RepositoryMethods.attr_names(self).each { |n| constructor_attrs[n] = attrs.key?(n) ? attrs[n] : nil }
          aggregate = new(**constructor_attrs)
          aggregate.stamp_created! if aggregate.respond_to?(:stamp_created!)
          repo.save(aggregate)
          aggregate
        end
      end

      # Defines instance-level persistence methods on the aggregate class.
      #
      # @param klass [Class] the aggregate class to augment
      # @param repo [Object] the repository adapter instance
      # @return [void]
      def self.bind_instance_methods(klass, repo)
        klass.define_method(:destroyed?) { !!@__destroyed__ }

        klass.define_method(:save) do
          return self if destroyed?
          repo.save(self)
          self
        end

        klass.define_method(:destroy) do
          repo.delete(id)
          @__destroyed__ = true
          self
        end

        klass.define_method(:update) do |**new_attrs|
          return self if destroyed?
          constructor_attrs = { id: id }
          RepositoryMethods.attr_names(self.class).each do |name|
            constructor_attrs[name] = new_attrs.key?(name) ? new_attrs[name] : send(name)
          end
          updated = self.class.new(**constructor_attrs)
          updated.instance_variable_set(:@created_at, created_at) if respond_to?(:created_at)
          updated.stamp_updated! if updated.respond_to?(:stamp_updated!)
          repo.save(updated)
          updated
        end
      end

      private_class_method :bind_class_methods, :bind_instance_methods

      # Returns the list of attribute names for an aggregate class.
      #
      # Prefers +hecks_attributes+ metadata if available (set by the code generator),
      # otherwise falls back to reflecting on the constructor's keyword parameters,
      # excluding +:id+ which is handled separately.
      #
      # @param klass [Class] the aggregate class to introspect
      # @return [Array<Symbol>] the attribute names (excluding :id)
      def self.attr_names(klass)
        if klass.respond_to?(:hecks_attributes)
          klass.hecks_attributes.map(&:name)
        else
          klass.instance_method(:initialize).parameters
            .select { |type, _| type == :key || type == :keyreq }
            .map { |_, name| name }
            .reject { |n| n == :id }
        end
      end
      end
  end
end
