module Hecks
  module ValidationRules
    module Structure

    # Hecks::ValidationRules::Structure::ValidPolicyEvents
    #
    # Produces advisory warnings (not blocking errors) when policies listen for
    # events that are not defined in the current domain. Cross-domain events are
    # valid -- they arrive via the shared event bus from other domains -- so this
    # rule only warns to help catch typos or missing event definitions.
    #
    # Checks both aggregate-level policies and domain-level policies.
    #
    # Part of the ValidationRules::Structure group -- run by +Hecks.validate+.
    #
    class ValidPolicyEvents < BaseRule
      # Returns no errors. This rule only produces warnings.
      #
      # @return [Array<String>] always returns an empty array
      def errors
        []
      end

      # Returns warnings for policies that listen for events not defined in
      # this domain. Includes a hint listing known events when available.
      # Checks both aggregate-scoped policies and domain-level policies.
      #
      # @return [Array<String>] warning messages for policies listening to unknown events
      def warnings
        result = []
        all_events = @domain.aggregates.flat_map { |a| a.events.map(&:name) }

        @domain.aggregates.each do |agg|
          agg.policies.each do |policy|
            unless all_events.include?(policy.event_name)
              hint = all_events.any? ? " Known events: #{all_events.join(', ')}." : ""
              result << "Policy #{policy.name} in #{agg.name} listens for #{policy.event_name} (not in this domain — must come from another domain).#{hint}"
            end
          end
        end

        @domain.policies.each do |policy|
          unless all_events.include?(policy.event_name)
            hint = all_events.any? ? " Known events: #{all_events.join(', ')}." : ""
            result << "Domain policy #{policy.name} listens for #{policy.event_name} (not in this domain — must come from another domain).#{hint}"
          end
        end

        result
      end
    end
    Hecks.register_validation_rule(ValidPolicyEvents)
    end
  end
end
