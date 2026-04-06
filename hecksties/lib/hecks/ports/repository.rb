  # Hecks::Persistence
  #
  # The top-level module for all persistence-related concerns in the Hecks framework.
  # Groups CRUD repository methods, collection proxies for list attributes,
  # reference resolution for cross-aggregate lookups, and optional event sourcing
  # via EventRecorder.
  #
  # This module acts as the wiring layer between domain aggregate classes and their
  # underlying storage. It is called during application boot to attach persistence
  # behavior to each aggregate class without polluting the domain model itself.
  #
  # == Usage
  #
  #   Persistence.bind(PizzaClass, pizza_aggregate, repo)
  #   # Now PizzaClass has .create, .find, .all, #save, #update, #destroy, etc.
  #
  #   Persistence.bind_event_recorder(PizzaClass, recorder)
  #   # Now PizzaClass.history(id) returns event history
  #
  # == Submodules
  #
  # - +RepositoryMethods+ -- CRUD class/instance methods (find, create, save, update, destroy)
  # - +CollectionMethods+ -- Accessor methods for list attributes returning CollectionProxy
  # - +CollectionProxy+   -- Persistence-aware wrapper around list attributes
  # - +CollectionItem+    -- Delegator wrapper for individual items in a collection
  # - +ReferenceMethods+  -- Resolves reference_to attributes into aggregate lookups
  # - +EventRecorder+     -- SQL-backed event store for event-sourced aggregates
  #
module Hecks
  module Persistence
      autoload :RepositoryMethods, "hecks/ports/repository/repository_methods"
      autoload :CollectionMethods, "hecks/ports/repository/collection_methods"
      autoload :CollectionProxy,   "hecks/ports/repository/collection_proxy"
      autoload :CollectionItem,    "hecks/ports/repository/collection_item"
      autoload :ReferenceMethods,  "hecks/ports/repository/reference_methods"
      autoload :EventRecorder,    "hecks/ports/repository/event_recorder"

      # Wires CRUD, collection, and reference methods onto an aggregate class.
      #
      # Called during application boot for each aggregate. Delegates to the three
      # sub-binders: RepositoryMethods (CRUD), CollectionMethods (list attribute
      # proxies), and ReferenceMethods (cross-aggregate reference resolution).
      #
      # @param klass [Class] the aggregate class to augment (e.g., Pizza)
      # @param aggregate [Hecks::DomainModel::Aggregate] the domain model metadata
      #   describing this aggregate's attributes, value objects, and entities
      # @param repo [Object] the repository adapter instance (memory or SQL) that
      #   handles actual storage operations (save, find, delete, all)
      # @return [void]
      def self.bind(klass, aggregate, repo)
        RepositoryMethods.bind(klass, repo)
        CollectionMethods.bind(klass, aggregate, repo)
        ReferenceMethods.bind(klass, aggregate)
      end

      # Attaches an event recorder to the aggregate and its command classes.
      #
      # Defines a +.history(id)+ class method on the aggregate that returns the
      # event stream for a given entity. Also wires the recorder into each command
      # class under the aggregate's +Commands+ namespace so that command execution
      # automatically records domain events.
      #
      # @param klass [Class] the aggregate class to augment (e.g., Pizza)
      # @param recorder [Hecks::Persistence::EventRecorder] the event recorder
      #   instance backed by a SQL events table
      # @return [void]
      def self.bind_event_recorder(klass, recorder)
        agg_type = klass.name.split("::").last
        klass.define_singleton_method(:__hecks_event_recorder__) { recorder }
        klass.define_singleton_method(:history) do |id|
          recorder.history(agg_type, id)
        end

        # Wire recorder into command classes
        cmd_mod = begin; klass.const_get(:Commands); rescue NameError; nil; end
        return unless cmd_mod
        cmd_mod.constants.each do |name|
          cmd_class = cmd_mod.const_get(name)
          next unless cmd_class.respond_to?(:event_recorder=)
          cmd_class.event_recorder = recorder
          cmd_class.aggregate_type = agg_type
        end
      end
  end
end
