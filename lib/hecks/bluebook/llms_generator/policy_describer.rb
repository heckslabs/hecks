module Hecks
  class LlmsGenerator
    # Hecks::LlmsGenerator::PolicyDescriber
    #
    # Renders aggregate-level and domain-level policies, plus reactive flow
    # chains, as plain-text lines for an llms.txt document.
    #
    #   class MyGenerator
    #     include PolicyDescriber
    #   end
    #
    module PolicyDescriber
      private

      # @return [Array<String>]
      def describe_aggregate_policies(agg)
        policies = agg.policies
        return [] if policies.empty?

        lines = ["### Policies", ""]
        policies.each { |pol| lines << format_policy(pol) }
        lines << ""
        lines
      end

      # Describe domain-level (cross-aggregate) policies.
      #
      # @return [Array<String>]
      def describe_domain_policies
        policies = @domain.policies
        return [] if policies.empty?

        lines = ["## Domain Policies", ""]
        policies.each { |pol| lines << format_policy(pol) }
        lines << ""
        lines
      end

      # Format a single policy as a readable line.
      #
      # @param pol [Hecks::BluebookModel::Behavior::Policy]
      # @return [String]
      def format_policy(pol)
        if pol.reactive?
          async_note = pol.async ? " [async]" : ""
          "- #{pol.name}: when #{pol.event_name} occurs, trigger #{pol.trigger_command}#{async_note}"
        else
          "- #{pol.name}: guard policy"
        end
      end

      # Build the reactive flow chains section, tracing command -> event ->
      # policy -> command chains across all aggregates and domain policies.
      #
      # @return [Array<String>]
      def describe_reactive_flows
        chains = build_chains
        return [] if chains.empty?

        lines = ["## Reactive Flows", ""]
        lines << "These are the command -> event -> policy -> command chains:"
        lines << ""
        chains.each { |chain| lines << "- #{chain}" }
        lines << ""
        lines
      end

      # Build chain descriptions by matching command events to policies.
      #
      # @return [Array<String>]
      def build_chains
        all_policies = collect_all_policies
        aggregates = @domain.aggregates

        chains = []
        aggregates.each do |agg|
          events = agg.events
          agg.commands.each_with_index do |cmd, i|
            event = events[i]
            next unless event

            event_name = event.name
            matching = all_policies.select { |p| p.reactive? && p.event_name == event_name }
            matching.each do |pol|
              chains << "#{cmd.name} -> #{event_name} -> #{pol.name} -> #{pol.trigger_command}"
            end
          end
        end
        chains
      end

      # @return [Array]
      def collect_all_policies
        all = @domain.policies.dup
        @domain.aggregates.each { |agg| all.concat(agg.policies) }
        all
      end
    end
  end
end
