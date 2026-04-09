module Hecks
  module ValidationRules
    module Structure

    # Hecks::ValidationRules::Structure::UnreachableLifecycleStates
    #
    # Detects lifecycle states that cannot be reached from the default state
    # via any sequence of transitions. An unreachable state indicates a
    # modeling error -- either a missing transition or a state that should
    # be removed.
    #
    # For each aggregate with a lifecycle, performs a BFS from the default
    # state through all transitions to find reachable states, then compares
    # against all declared target states.
    #
    # Part of the ValidationRules::Structure group -- run by +Hecks.validate+.
    #
    #   rule = UnreachableLifecycleStates.new(domain)
    #   rule.errors  # => ["Warning: Unreachable lifecycle state 'archived' in Order ..."]
    #
    class UnreachableLifecycleStates < BaseRule
      # Returns no errors. This rule only produces warnings.
      #
      # @return [Array] always returns an empty array
      def errors
        []
      end

      # Checks each aggregate's lifecycle for unreachable states.
      #
      # @return [Array<String>] warning messages for unreachable states
      def warnings
        result = []

        @domain.aggregates.each do |agg|
          next unless agg.lifecycle

          reachable = reachable_states(agg.lifecycle)
          all_states = declared_states(agg.lifecycle)

          (all_states - reachable).each do |state|
            result << "Warning: Unreachable lifecycle state '#{state}' in #{agg.name} -- " \
                      "no transition path from '#{agg.lifecycle.default}'. " \
                      "Add a transition that leads to '#{state}' or remove it from the lifecycle."
          end
        end

        result
      end

      private

      # BFS from the default state through all transitions to find reachable states.
      #
      # @param lifecycle [Lifecycle] the lifecycle to analyze
      # @return [Set<String>] all states reachable from the default
      def reachable_states(lifecycle)
        visited = Set.new([lifecycle.default])
        queue = [lifecycle.default]

        while (current = queue.shift)
          lifecycle.transitions.each_value do |entry|
            target = entry.respond_to?(:target) ? entry.target : entry.to_s
            from = entry.respond_to?(:from) ? entry.from : nil

            reachable_from_current = if from.nil?
              true
            elsif from.is_a?(Array)
              from.include?(current)
            else
              from.to_s == current
            end

            if reachable_from_current && !visited.include?(target)
              visited << target
              queue << target
            end
          end
        end

        visited
      end

      # Collects all declared target states from transitions.
      #
      # @param lifecycle [Lifecycle] the lifecycle to analyze
      # @return [Set<String>] all target states declared in transitions
      def declared_states(lifecycle)
        states = Set.new([lifecycle.default])
        lifecycle.transitions.each_value do |entry|
          target = entry.respond_to?(:target) ? entry.target : entry.to_s
          states << target
        end
        states
      end
    end
    Hecks.register_validation_rule(UnreachableLifecycleStates)
    end
  end
end
