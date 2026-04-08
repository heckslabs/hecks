module Hecks
  module Persistence
    # Hecks::Persistence::CollectionMethods
    #
    # Binds collection proxy accessors onto aggregate classes during application boot.
    # For each list attribute whose type corresponds to a value object or entity defined
    # on the aggregate, this module defines an instance method that returns a
    # CollectionProxy -- a persistence-aware wrapper that supports create, delete,
    # and clear operations on the collection.
    #
    # This module is called by +Persistence.bind+ and should not be used directly.
    #
    # == How it works
    #
    # 1. Iterates over the aggregate's attributes that are marked as lists (+list?+)
    # 2. For each, finds the matching value object or entity definition
    # 3. Resolves the corresponding Ruby class constant on the aggregate class
    # 4. Defines an instance method (e.g., +toppings+) that returns a CollectionProxy
    #
    # == Usage
    #
    #   CollectionMethods.bind(PizzaClass, pizza_aggregate, repo)
    #   pizza = Pizza.create(name: "Margherita")
    #   pizza.toppings.create(name: "Mozzarella", amount: 2)
    #   pizza.toppings.count  # => 1
    #
    module CollectionMethods
      # Defines collection accessor methods on the given aggregate class.
      #
      # For each list attribute on the aggregate whose type matches a value object
      # or entity, defines an instance method that returns a CollectionProxy wrapping
      # the underlying array with persistence-aware mutation methods.
      #
      # @param klass [Class] the aggregate class to augment (e.g., Pizza)
      # @param aggregate [Hecks::BluebookModel::Aggregate] the domain model metadata
      #   describing this aggregate's attributes, value objects, and entities
      # @param repo [Object] the repository adapter instance for persisting changes
      #   when collection items are added or removed
      # @return [void]
      def self.bind(klass, aggregate, repo)
        aggregate.attributes.select(&:list?).each do |list_attr|
          vo = aggregate.value_objects.find { |v| v.name == list_attr.type.to_s }
          vo ||= aggregate.entities.find { |e| e.name == list_attr.type.to_s }
          next unless vo
          attr_name = list_attr.name
          vo_class = begin; klass.const_get(vo.name); rescue NameError; nil; end
          next unless vo_class
          repo_ref = repo

          klass.define_method(attr_name) do
            items = instance_variable_get(:"@#{attr_name}") || []
            Persistence::CollectionProxy.new(items: items, owner: self, attr_name: attr_name,
                                value_object_class: vo_class, repo: repo_ref)
          end
        end
      end
      end
  end
end
