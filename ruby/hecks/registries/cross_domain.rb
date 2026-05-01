# Hecks::CrossDomainMethods
#
# Cross-domain queries, views, and shared event bus.
# Extracted from the Hecks module.
#
module Hecks
  # Hecks::CrossDomainMethods
  #
  # Registry for cross-domain queries, views, and the shared event bus extended onto the Hecks module.
  #
  module CrossDomainMethods
    def cross_domain_queries
      @cross_domain_queries ||= Registry.new
    end

    def cross_domain_views
      @cross_domain_views ||= Registry.new
    end

    def event_bus
      @shared_event_bus
    end

    def queue
      @queue ||= Queue::MemoryQueue.new
    end

    def queue=(q)
      @queue = q
    end

    def cross_domain_query(name, &block)
      cross_domain_queries.register(name, CrossDomainQuery.new(name, &block))
    end

    def query(name, **params)
      q = cross_domain_queries[name]
      raise Error, "Unknown cross-domain query: #{name}" unless q
      q.call(**params)
    end

    def cross_domain_view(name, &block)
      view = CrossDomainView.new(name, &block)
      cross_domain_views.register(name, view)
      view.subscribe(@shared_event_bus) if @shared_event_bus
      view
    end
  end
end
