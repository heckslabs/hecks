module Hecks
  class BluebookVisualizer
    # Hecks::DomainVisualizer::BehaviorDiagram
    #
    # Builds the Mermaid flowchart portion showing command-to-event flows
    # and policy chains (event triggers command). Mixed into DomainVisualizer.
    #
    # The flowchart uses Mermaid's LR (left-to-right) direction. Each aggregate
    # is rendered as a subgraph containing its commands (rectangles) and events
    # (rounded rectangles / stadium shapes). Policies are drawn as dotted arrows
    # connecting events to the commands they trigger, potentially across aggregates.
    #
    #   include BehaviorDiagram
    #   generate_behavior  # => "flowchart LR\n    subgraph Pizza\n    ..."
    #
    module BehaviorDiagram
      # Generate the complete Mermaid flowchart string for the domain's
      # behavioral model. Includes subgraphs for each aggregate and
      # dotted-line policy links between events and commands.
      #
      # @return [String] Mermaid flowchart source code
      def generate_behavior
        lines = ["flowchart LR"]

        @domain.aggregates.each do |agg|
          prefix = agg.name
          lines << "    subgraph #{prefix}"

          agg.commands.each_with_index do |cmd, i|
            event = agg.events[i]
            cmd_id = node_id(prefix, cmd.name)
            lines << "        #{cmd_id}[#{cmd.name}]"

            if event
              evt_id = node_id(prefix, event.name)
              lines << "        #{evt_id}([#{event.name}])"
              lines << "        #{cmd_id} --> #{evt_id}"
            end
          end

          lines << "    end"
        end

        policy_links(lines)
        lines.join("\n")
      end

      private

      # Add dotted-line policy links to the diagram. Each policy connects
      # an event node to a command node with a labeled edge showing the
      # policy name and async status.
      #
      # @param lines [Array<String>] the diagram lines array to append to
      # @return [void]
      def policy_links(lines)
        all_policies = @domain.aggregates.flat_map(&:policies) + @domain.policies

        all_policies.each do |pol|
          evt_agg, evt_id = find_event_node(pol.event_name)
          cmd_agg, cmd_id = find_command_node(pol.trigger_command)
          next unless evt_id && cmd_id

          label = pol.async ? "#{pol.name} [async]" : pol.name
          lines << "    #{evt_id} -.->|#{label}| #{cmd_id}"
        end
      end

      # Find the Mermaid node ID for a named event across all aggregates.
      #
      # @param event_name [String] the event name to search for
      # @return [Array(String, String), nil] [aggregate_name, node_id] tuple,
      #   or nil if the event is not found
      def find_event_node(event_name)
        @domain.aggregates.each do |agg|
          agg.events.each do |evt|
            return [agg.name, node_id(agg.name, evt.name)] if evt.name == event_name
          end
        end
        nil
      end

      # Find the Mermaid node ID for a named command across all aggregates.
      #
      # @param command_name [String] the command name to search for
      # @return [Array(String, String), nil] [aggregate_name, node_id] tuple,
      #   or nil if the command is not found
      def find_command_node(command_name)
        @domain.aggregates.each do |agg|
          agg.commands.each do |cmd|
            return [agg.name, node_id(agg.name, cmd.name)] if cmd.name == command_name
          end
        end
        nil
      end

      # Generate a unique Mermaid node identifier by combining the aggregate
      # prefix with the element name.
      #
      # @param prefix [String] the aggregate name used as a namespace
      # @param name [String] the command or event name
      # @return [String] a unique node ID (e.g., "Pizza_CreatePizza")
      def node_id(prefix, name)
        "#{prefix}_#{name}"
      end
    end
  end
end
