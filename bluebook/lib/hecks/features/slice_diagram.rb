  # Hecks::Features::SliceDiagram
  #
  # Generates a Mermaid flowchart where each vertical slice is a labeled
  # subgraph. Commands are rectangles, events are stadium shapes, and
  # policies are dotted arrows connecting them.
  #
  #   diagram = SliceDiagram.new(domain).generate
  #   puts diagram  # => "flowchart LR\n  subgraph ..."
  #
module Hecks::Features

  class SliceDiagram
    # @param domain [Hecks::DomainModel::Structure::Domain]
    def initialize(domain)
      @domain = domain
    end

    # Generate a Mermaid flowchart with slices as subgraphs.
    #
    # @return [String] Mermaid flowchart markup
    def generate
      slices = SliceExtractor.new(@domain).extract
      return "flowchart LR\n  NoSlices[No vertical slices found]" if slices.empty?

      lines = ["flowchart LR"]

      slices.each_with_index do |slice, i|
        lines << "  subgraph slice#{i}[\"#{slice.name}\"]"
        lines << "    direction TB" if slice.depth > 2

        slice.steps.each_with_index do |step, j|
          node_id = "s#{i}_#{j}"
          case step.type
          when :command
            lines << "    #{node_id}[#{step.command}]"
            event_id = "#{node_id}_evt"
            lines << "    #{event_id}([#{step.event}])"
            lines << "    #{node_id} --> #{event_id}"
          when :policy
            lines << "    #{node_id}{{#{step.policy}}}"
            prev_event = find_event_node(i, step.event, slice.steps, j)
            lines << "    #{prev_event} -.-> #{node_id}" if prev_event
            next_cmd = find_command_node(i, step.command, slice.steps, j)
            lines << "    #{node_id} --> #{next_cmd}" if next_cmd
          when :cycle
            lines << "    #{node_id}>CYCLE: #{step.command}]"
          end
        end

        lines << "  end"
      end

      lines.join("\n")
    end

    private

    def find_event_node(slice_idx, event_name, steps, before_idx)
      steps.each_with_index do |step, j|
        next if j >= before_idx
        return "s#{slice_idx}_#{j}_evt" if step.type == :command && step.event == event_name
      end
      nil
    end

    def find_command_node(slice_idx, cmd_name, steps, after_idx)
      steps.each_with_index do |step, j|
        next if j <= after_idx
        return "s#{slice_idx}_#{j}" if step.type == :command && step.command == cmd_name
      end
      nil
    end
  end
end
