module Hecks
  module ValidationRules
    module Structure

    # Hecks::ValidationRules::Structure::PolicyCycleDetection
    #
    # Detects circular policy chains in the domain model. A cycle occurs when
    # reactive policies form a loop: Event A triggers Command B, which emits
    # Event C, which triggers Command D, which emits Event A again.
    #
    # Builds a directed graph from events to the events emitted by the commands
    # they trigger, then walks it looking for back-edges (cycles).
    #
    # Part of the ValidationRules::Structure group -- run by +Hecks.validate+.
    #
    #   rule = PolicyCycleDetection.new(domain)
    #   rule.errors  # => ["Warning: Policy cycle: CreatedPizza → PrepareOrder → ..."]
    #
    class PolicyCycleDetection < BaseRule
      # Returns no errors. This rule only produces warnings.
      #
      # @return [Array] always returns an empty array
      def errors
        []
      end

      # Builds a policy graph and reports any cycles found as warnings.
      #
      # @return [Array<String>] warning messages for each detected cycle
      def warnings
        graph = build_event_graph
        cycles = detect_cycles(graph)

        cycles.map do |cycle|
          path = cycle.join(" -> ")
          "Warning: Policy cycle: #{path}. " \
            "Break the cycle by removing or conditioning one of the policies in the chain."
        end
      end

      private

      # Builds a mapping from event names to the event names that result from
      # the commands those events trigger (via reactive policies).
      #
      # @return [Hash{String => Array<String>>}] adjacency list of event -> emitted events
      def build_event_graph
        graph = Hash.new { |h, k| h[k] = [] }
        all_commands = command_index

        all_reactive_policies.each do |policy|
          triggered = all_commands[bare_name(policy.trigger_command)]
          next unless triggered

          triggered.event_names.each do |emitted|
            graph[policy.event_name.to_s] << emitted.to_s
          end
        end

        graph
      end

      # Collects all reactive policies from both aggregate and domain level.
      #
      # @return [Array<Policy>] all reactive policies in the domain
      def all_reactive_policies
        agg_policies = @domain.aggregates.flat_map { |a| a.policies.select(&:reactive?) }
        domain_policies = @domain.policies.select(&:reactive?)
        agg_policies + domain_policies
      end

      # Builds an index of command name -> command object for quick lookup.
      #
      # @return [Hash{String => Command}] bare command name -> command
      def command_index
        index = {}
        @domain.aggregates.each do |agg|
          agg.commands.each { |cmd| index[cmd.name.to_s] = cmd }
        end
        index
      end

      # Extracts the bare name from a possibly qualified command name.
      #
      # @param name [String] e.g. "Identity::AuditLog::RecordEntry" or "RecordEntry"
      # @return [String] the bare name (e.g. "RecordEntry")
      def bare_name(name)
        name.to_s.include?("::") ? name.to_s.split("::").last : name.to_s
      end

      # DFS-based cycle detection on the event graph.
      #
      # @param graph [Hash{String => Array<String>}] adjacency list
      # @return [Array<Array<String>>] list of cycles, each as an array of event names
      def detect_cycles(graph)
        visited = {}
        path = []
        cycles = []

        graph.each_key do |node|
          next if visited[node] == :done
          dfs(node, graph, visited, path, cycles)
        end

        cycles
      end

      # Recursive DFS that tracks the current path to detect back-edges.
      def dfs(node, graph, visited, path, cycles)
        return if visited[node] == :done

        if visited[node] == :in_progress
          cycle_start = path.index(node)
          cycles << path[cycle_start..] + [node] if cycle_start
          return
        end

        visited[node] = :in_progress
        path.push(node)

        (graph[node] || []).each do |neighbor|
          dfs(neighbor, graph, visited, path, cycles)
        end

        path.pop
        visited[node] = :done
      end
    end
    Hecks.register_validation_rule(PolicyCycleDetection)
    end
  end
end
