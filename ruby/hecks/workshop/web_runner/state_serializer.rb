Hecks::Chapters.load_aggregates(
  Hecks::Workshop::SerializersParagraph,
  base_dir: File.expand_path("state_serializer", __dir__)
)

module Hecks
  class Workshop
    class WebRunner
      # Hecks::Workshop::WebRunner::StateSerializer
      #
      # Serializes the current workshop state into a JSON-ready hash for
      # the browser console. Delegates to focused sub-serializers for
      # aggregates, events, services, policy flows, and mermaid diagrams.
      #
      #   StateSerializer.new(workshop).serialize
      #   # => { mode: "sketch", domain_name: "Pizzas", aggregates: [...], events: [] }
      #
      class StateSerializer
        def initialize(workshop, domain_groups: {}, domains: [])
          @workshop = workshop
          @aggregate_serializer = AggregateSerializer.new(workshop, domain_groups: domain_groups, domains: domains)
          @event_serializer     = EventSerializer.new(workshop)
          @service_serializer   = ServiceSerializer.new(domains)
        end

        def serialize
          aggs = @aggregate_serializer.call
          {
            mode:         @workshop.play? ? "play" : "sketch",
            domain_name:  @workshop.name,
            aggregates:   aggs,
            services:     @service_serializer.call,
            policy_flows: PolicyFlowBuilder.new(aggs).call,
            events:       @event_serializer.call,
            mermaid:      MermaidBuilder.new(aggs).call
          }
        end
      end
    end
  end
end
