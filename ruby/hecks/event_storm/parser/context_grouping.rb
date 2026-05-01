module Hecks
  module EventStorm
    class Parser
      # Hecks::EventStorm::Parser::ContextGrouping
      #
      # Mixin that splits event storm text into bounded contexts and groups
      # parsed elements by context markers (## Bounded Context: Name).
      #
      # Architecture: included by Hecks::EventStorm::Parser. Relies on the host
      # class defining PATTERNS, ParsedContext, and the PatternMatching mixin
      # (for parse_line and normalize_name).
      #
      #   contexts = extract_contexts(lines)
      #   contexts.first.name  # => "Ordering"
      #
      module ContextGrouping
        private

        # Extracts all bounded contexts from the document lines.
        #
        # Splits lines by context markers, parses each chunk into a ParsedContext,
        # and filters out empty contexts (those with no recognized elements).
        #
        # @param lines [Array<String>] all lines of the event storm document
        # @return [Array<ParsedContext>] non-empty parsed contexts
        def extract_contexts(lines)
          chunks = split_by_context(lines)
          contexts = chunks.map { |name, ctx_lines| parse_context(name, ctx_lines) }
          contexts.reject { |ctx| ctx.elements.empty? }
        end

        # Splits document lines into chunks delimited by context headers.
        #
        # Lines before the first context header are grouped under "Default".
        # Each chunk is a [name, lines] pair.
        #
        # @param lines [Array<String>] all document lines
        # @return [Array<Array(String, Array<String>)>] pairs of [context_name, lines]
        def split_by_context(lines)
          contexts = []
          current_name = "Default"
          current_lines = []

          lines.each do |line|
            match = line.match(PATTERNS[:context])
            if match
              contexts << [current_name, current_lines] unless current_lines.empty?
              current_name = match[1].strip
              current_lines = []
            else
              current_lines << line
            end
          end

          contexts << [current_name, current_lines] unless current_lines.empty?
          contexts
        end

        # Parses a single bounded context's lines into a ParsedContext.
        #
        # Iterates through cleaned lines, using parse_line (from PatternMatching)
        # to identify elements. Tracks a "current command" to associate aggregates,
        # read models, and external systems with the most recent command.
        # After parsing, wires policies to their trigger commands.
        #
        # @param name [String] the bounded context name
        # @param lines [Array<String>] the lines belonging to this context
        # @return [ParsedContext] the parsed context with all its elements
        def parse_context(name, lines)
          elements = []
          current_command = nil

          lines.each do |line|
            cleaned = line.gsub(/^[\s|v+\->]+/, "")
            next if cleaned.empty? || cleaned.start_with?("#") || cleaned.include?("LEGEND") ||
                    cleaned.include?("=====")

            parsed = parse_line(cleaned)
            next unless parsed

            if parsed[:command]
              current_command = parsed[:command]
              elements << current_command
            end

            if parsed[:event]
              elements << parsed[:event]
              current_command = nil
            end

            if parsed[:policy]
              elements << parsed[:policy]
              current_command = nil
            end

            if parsed[:aggregate] && current_command
              current_command.meta[:aggregate] = parsed[:aggregate].name
            end

            if parsed[:read_model] && current_command
              current_command.meta[:read_models] ||= []
              current_command.meta[:read_models] << parsed[:read_model].name
            end

            if parsed[:external] && current_command
              current_command.meta[:external_systems] ||= []
              current_command.meta[:external_systems] << parsed[:external].name
            elsif parsed[:external]
              elements << parsed[:external]
            end

            elements << parsed[:actor] if parsed[:actor]
            elements << parsed[:hotspot] if parsed[:hotspot]
          end

          wire_policies_to_commands(elements)
          ParsedContext.new(name: name, elements: elements)
        end

        # Wires policies to the next command that follows them in element order.
        #
        # For each policy element, finds the next :command element after it in the
        # array and sets the policy's :trigger metadata to that command's name.
        # This implements the event storm convention where a policy triggers the
        # command that follows it in the flow.
        #
        # @param elements [Array<ParsedElement>] the elements array (mutated in place)
        # @return [void]
        def wire_policies_to_commands(elements)
          elements.each_with_index do |el, i|
            next unless el.type == :policy
            next_cmd = elements[(i + 1)..].find { |e| e.type == :command }
            el.meta[:trigger] = next_cmd.name if next_cmd
          end
        end
      end
    end
  end
end
