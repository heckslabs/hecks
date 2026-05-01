  # Hecks::FlowGenerator
  #
  # Analyzes a domain's reactive chains and produces human-readable flow
  # descriptions. Walks all aggregates to find commands and their inferred
  # events, then traces policy triggers to build chains:
  #   Command A -> Event A -> Policy P -> Command B -> Event B -> ...
  #
  # Detects cycles and marks them. Outputs two formats:
  #   - Plain English text via +generate_text+
  #   - Mermaid sequence diagrams via +generate_mermaid+
  #
  #   generator = Hecks::FlowGenerator.new(domain)
  #   puts generator.generate_text
  #   puts generator.generate_mermaid
  #
module Hecks
  class FlowGenerator
    # @param domain [Hecks::BluebookModel::Structure::Domain] the domain to analyze
    def initialize(domain)
      @domain = domain
    end

    # Generate plain English flow descriptions showing the reactive chains.
    #
    # @return [String] multi-line text describing each flow
    def generate_text
      flows = trace_flows
      return "No reactive flows found." if flows.empty?

      flows.map { |flow| format_text_flow(flow) }.join("\n\n")
    end

    # Generate a Mermaid sequence diagram showing the reactive chains.
    #
    # @return [String] Mermaid sequenceDiagram markup
    def generate_mermaid
      flows = trace_flows
      return "sequenceDiagram\n  Note over Domain: No reactive flows" if flows.empty?

      lines = ["sequenceDiagram"]
      participants = collect_participants(flows)
      participants.each { |p| lines << "  participant #{p}" }

      flows.each do |flow|
        lines.concat(format_mermaid_flow(flow))
      end

      lines.join("\n")
    end

    # Build lookup tables and trace all reactive flows from entry-point commands.
    #
    # @return [Array<Hash>] array of flow hashes with :name, :steps, :cyclic keys
    def trace_flows
      build_indexes
      entry_commands = find_entry_commands
      entry_commands.map { |cmd_key| trace_from(cmd_key) }.compact
    end

    private

    # Build indexes mapping event names to policies and command names to aggregates.
    #
    # @return [void]
    def build_indexes
      @command_to_aggregate = {}
      @command_to_event = {}
      @event_to_policies = Hash.new { |h, k| h[k] = [] }

      @domain.aggregates.each do |agg|
        agg.commands.each do |cmd|
          key = cmd.name
          @command_to_aggregate[key] = agg.name
          @command_to_event[key] = cmd.event_names.first
        end

        agg.policies.select(&:reactive?).each do |pol|
          @event_to_policies[pol.event_name] << pol
        end
      end

      @domain.policies.select(&:reactive?).each do |pol|
        @event_to_policies[pol.event_name] << pol
      end
    end

    # Find commands that start reactive chains -- commands whose events
    # trigger at least one policy. Also includes cycle-only commands where
    # every participant is a policy target (no natural entry point).
    #
    # @return [Array<String>] command names that begin flows
    def find_entry_commands
      triggered_commands = Set.new
      @event_to_policies.each_value do |pols|
        pols.each { |pol| triggered_commands << pol.trigger_command }
      end

      # Commands that emit policy-triggering events and are NOT themselves triggered
      entries = @command_to_event.select do |cmd_name, event_name|
        @event_to_policies.key?(event_name) && !triggered_commands.include?(cmd_name)
      end.keys

      # Find cycle-only commands: all participants are triggered, pick one per cycle
      if entries.empty?
        reactive_cmds = @command_to_event.select do |_, event_name|
          @event_to_policies.key?(event_name)
        end.keys
        entries = reactive_cmds.take(1) unless reactive_cmds.empty?
      end

      entries
    end

    # Trace a single reactive chain starting from the given command.
    #
    # @param cmd_name [String] command name to start from
    # @return [Hash, nil] flow hash with :name, :steps, :cyclic, or nil if no chain
    def trace_from(cmd_name)
      steps = []
      visited = Set.new
      cyclic = false

      queue = [cmd_name]
      while (current_cmd = queue.shift)
        if visited.include?(current_cmd)
          cyclic = true
          steps << { type: :cycle, command: current_cmd }
          break
        end
        visited << current_cmd

        agg_name = @command_to_aggregate[current_cmd]
        event_name = @command_to_event[current_cmd]
        next unless agg_name && event_name

        steps << { type: :command, command: current_cmd, aggregate: agg_name, event: event_name }

        policies = @event_to_policies[event_name]
        policies.each do |pol|
          target_agg = @command_to_aggregate[pol.trigger_command]
          steps << { type: :policy, policy: pol.name, event: event_name,
                     command: pol.trigger_command, aggregate: target_agg }
          queue << pol.trigger_command
        end
      end

      return nil if steps.size < 2

      flow_name = derive_flow_name(steps)
      { name: flow_name, steps: steps, cyclic: cyclic }
    end

    # Derive a human-readable name for the flow from first and last steps.
    #
    # @param steps [Array<Hash>] flow steps
    # @return [String] flow name like "Loan Issuance -> Disbursement"
    def derive_flow_name(steps)
      first_cmd = steps.first[:command]
      last_step = steps.reject { |s| s[:type] == :cycle }.last
      last_cmd = last_step[:command]
      "#{humanize_command(first_cmd)} -> #{humanize_command(last_cmd)}"
    end

    # Convert a PascalCase command name to a readable label.
    #
    # @param name [String] e.g. "IssueLoan"
    # @return [String] e.g. "Loan Issuance"
    def humanize_command(name)
      Hecks::Utils.humanize(name)
    end

    # Format a single flow as plain English text.
    #
    # @param flow [Hash] flow with :name, :steps, :cyclic
    # @return [String]
    def format_text_flow(flow)
      lines = ["Flow: #{flow[:name]}"]
      lines << "  [CYCLIC]" if flow[:cyclic]

      step_num = 0
      flow[:steps].each do |step|
        case step[:type]
        when :command
          step_num += 1
          lines << "  #{step_num}. #{step[:command]} (#{step[:aggregate]}) -> #{step[:event]}"
        when :policy
          step_num += 1
          target = step[:aggregate] ? " (#{step[:aggregate]})" : ""
          lines << "  #{step_num}. [Policy: #{step[:policy]}] on #{step[:event]} -> #{step[:command]}#{target}"
        when :cycle
          step_num += 1
          lines << "  #{step_num}. [CYCLE] back to #{step[:command]}"
        end
      end

      lines.join("\n")
    end

    # Collect unique participant names (aggregates) from all flows.
    #
    # @param flows [Array<Hash>] all traced flows
    # @return [Array<String>] ordered participant names
    def collect_participants(flows)
      names = []
      flows.each do |flow|
        flow[:steps].each do |step|
          agg = step[:aggregate]
          names << agg if agg && !names.include?(agg)
        end
      end
      names
    end

    # Format a single flow as Mermaid sequence diagram lines.
    #
    # @param flow [Hash] flow with :name, :steps, :cyclic
    # @return [Array<String>] Mermaid diagram lines
    def format_mermaid_flow(flow)
      lines = []
      command_steps = flow[:steps].select { |s| s[:type] == :command }
      policy_steps = flow[:steps].select { |s| s[:type] == :policy }

      command_steps.each do |step|
        lines << "  #{step[:aggregate]}->>#{step[:aggregate]}: #{step[:command]}"
      end

      policy_steps.each do |step|
        source_agg = find_event_source(step[:event])
        target_agg = step[:aggregate] || "Unknown"
        lines << "  #{source_agg}-->>#{target_agg}: #{step[:event]} [#{step[:policy]}]"
      end

      if flow[:cyclic]
        lines << "  Note over #{collect_participants([flow]).first}: CYCLE detected"
      end

      lines
    end

    # Find which aggregate emits a given event name.
    #
    # @param event_name [String] the event to look up
    # @return [String] aggregate name that emits this event
    def find_event_source(event_name)
      @command_to_event.each do |cmd, evt|
        return @command_to_aggregate[cmd] if evt == event_name
      end
      "Unknown"
    end
  end
end
