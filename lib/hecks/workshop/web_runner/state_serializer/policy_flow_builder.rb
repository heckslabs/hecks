module Hecks
  class Workshop
    class WebRunner
      class StateSerializer
        # Hecks::Workshop::WebRunner::StateSerializer::PolicyFlowBuilder
        #
        # Builds cross-aggregate policy flow edges from serialized aggregates.
        # Maps events to their source aggregate, then finds policies triggered
        # by events from a different aggregate.
        #
        #   PolicyFlowBuilder.new(aggregates).call
        #   # => [{ from: "Order", to: "Kitchen", event: "placed", ... }]
        #
        class PolicyFlowBuilder
          def initialize(aggregates)
            @aggregates = aggregates
          end

          def call
            event_source = build_event_source
            flows = []

            @aggregates.each do |agg|
              next unless agg[:policies].is_a?(Array)
              agg[:policies].each do |pol|
                next unless pol.is_a?(Hash) && pol[:event]
                source = event_source[pol[:event]]
                next unless source && source != agg[:name]
                flows << {
                  from: source, to: agg[:name],
                  event: pol[:event], trigger: pol[:trigger],
                  policy: pol[:name]
                }
              end
            end

            flows
          end

          private

          def build_event_source
            lookup = {}
            @aggregates.each do |agg|
              agg[:events].each { |e| lookup[e] = agg[:name] }
            end
            lookup
          end
        end
      end
    end
  end
end
