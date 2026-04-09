# Hecks::Capabilities::EventStore
#
# Event-sourced persistence capability. Aggregates annotated with
# :event_store in the hecksagon have their repository swapped for an
# event-sourced version that rebuilds state by replaying domain events
# through DSL-defined applier procs.
#
# == Hecksagon usage
#
#   Hecks.hecksagon "Pizzas" do
#     capabilities :event_store
#     Pizza.event_store
#   end
#
# == Bluebook usage
#
#   aggregate "Pizza" do
#     apply "CreatedPizza" do |event|
#       self.name = event.name
#     end
#     apply "ToppingAdded" do |event|
#       @toppings ||= []
#       @toppings << { name: event.name, amount: event.amount }
#     end
#   end
#
require_relative "dsl"
require_relative "event_store/store"
require_relative "event_store/repository"

module Hecks
  module Capabilities
    # Hecks::Capabilities::EventStore
    #
    # Swaps annotated aggregate repositories for event-sourced replaying versions.
    #
    module EventStore
      extend HecksTemplating::NamingHelpers

      # Apply the event_store capability to annotated aggregates.
      #
      # @param runtime [Hecks::Runtime] the booted runtime
      # @return [void]
      def self.apply(runtime)
        annotations = event_store_annotations(runtime)
        return if annotations.empty?

        domain = runtime.domain
        mod_name = bluebook_module_name(domain.name)
        mod = Object.const_get(mod_name)

        annotations.each do |annotation|
          agg_name = annotation[:aggregate].to_s.split("::").last
          agg = domain.aggregates.find { |a| a.name == agg_name }
          next unless agg

          wire_aggregate(runtime, agg, mod)
        end
      end

      # Find annotations where annotation == :event_store.
      #
      # @param runtime [Hecks::Runtime] the booted runtime
      # @return [Array<Hash>] matching annotations
      def self.event_store_annotations(runtime)
        hecksagon = runtime.instance_variable_get(:@hecksagon)
        return [] unless hecksagon&.respond_to?(:annotations)
        hecksagon.annotations.select { |a| a[:annotation] == :event_store }
      end
      private_class_method :event_store_annotations

      # Wire a single aggregate for event sourcing: create a store,
      # build a repository, subscribe to events, and swap the adapter.
      #
      # @param runtime [Hecks::Runtime] the runtime
      # @param agg [BluebookModel::Structure::Aggregate] the aggregate IR
      # @param mod [Module] the domain module
      # @return [void]
      def self.wire_aggregate(runtime, agg, mod)
        const_name = bluebook_constant_name(agg.name)
        agg_class = mod.const_get(const_name)
        appliers = agg.event_appliers
        store = Store.new
        repo = Repository.new(store, agg_class, appliers)

        subscribe_to_events(runtime, agg, store)
        runtime.swap_adapter(agg.name, repo)
      end
      private_class_method :wire_aggregate

      # Subscribe to all events for this aggregate so they get appended
      # to the store automatically when commands fire.
      #
      # @param runtime [Hecks::Runtime] the runtime
      # @param agg [BluebookModel::Structure::Aggregate] the aggregate IR
      # @param store [Store] the event store for this aggregate
      # @return [void]
      def self.subscribe_to_events(runtime, agg, store)
        event_names = agg.events.map(&:name)
        event_names.each do |event_name|
          runtime.event_bus.subscribe(event_name) do |event|
            id = event.respond_to?(:aggregate_id) ? event.aggregate_id : event.id
            store.append(id, event)
          end
        end
      end
      private_class_method :subscribe_to_events
    end
  end
end

Hecks.capability :event_store do
  description "Event-sourced persistence -- aggregates rebuilt from event history"
  on_apply do |runtime|
    Hecks::Capabilities::EventStore.apply(runtime)
  end
end
