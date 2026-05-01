module Hecks
  module EventStorm
    # Hecks::EventStorm::DslGenerator
    #
    # Generates a Hecks Ruby DSL file from a Parser::ParseResult. Produces
    # editable source code with TODO placeholders for attributes that need
    # to be filled in after the event storm.
    #
    # Part of the EventStorm module. Used by Hecks.from_event_storm to produce
    # the DSL string output.
    #
    #   result = EventStorm::Parser.new(source).parse
    #   dsl = EventStorm::DslGenerator.new(result, name: "Ordering").generate
    #   puts dsl  # => "Hecks.bluebook \"Ordering\" do ..."
    #
    class DslGenerator
      # Initializes a DslGenerator from a parse result.
      #
      # @param parse_result [Parser::ParseResult] the intermediate representation
      #   produced by Parser or YamlParser
      # @param name [String, nil] optional domain name override; falls back to
      #   parse_result.domain_name, then "MyDomain"
      def initialize(parse_result, name: nil)
        @parse_result = parse_result
        @name = name || parse_result.domain_name || "MyDomain"
      end

      # Generates the Hecks DSL source code string.
      #
      # Produces a complete Hecks.bluebook block with aggregate, command, and
      # policy declarations. Includes TODO comments for attributes that need
      # manual addition. Appends any parser warnings as Ruby comments.
      #
      # @return [String] the generated DSL source code, terminated with a newline
      def generate
        lines = ["# Auto-generated from event storm"]
        lines << "Hecks.bluebook \"#{@name}\" do"

        # Flatten all context elements into one set of aggregates
        all_elements = @parse_result.contexts.flat_map(&:elements)
        hotspots = all_elements.select { |e| e.type == :hotspot }
        aggregates = group_by_aggregate(all_elements)

        hotspots.each { |h| lines << "  # HOTSPOT: #{h.name}" }

        aggregates.each_with_index do |(agg_name, data), i|
          lines << "" if i > 0
          lines << "  aggregate \"#{agg_name}\" do"
          lines << "    # TODO: add attributes"

          data[:commands].each do |cmd|
            lines << ""
            lines << "    command \"#{cmd.name}\" do"
            lines << "      # TODO: add attributes"
            (cmd.meta[:read_models] || []).each do |rm|
              lines << "      read_model \"#{rm}\""
            end
            (cmd.meta[:external_systems] || []).each do |ext|
              lines << "      external \"#{ext}\""
            end
            lines << "    end"
          end

          data[:policies].each do |pol|
            lines << ""
            lines << "    policy \"#{pol.name}\" do"
            lines << "      on \"#{pol.meta[:event_name]}\""
            lines << "      trigger \"#{pol.meta[:trigger]}\""
            lines << "    end"
          end

          lines << "  end"
        end

        lines << "end"

        append_warnings(lines)

        lines.join("\n") + "\n"
      end

      private

      # Groups parsed elements by aggregate for DSL generation.
      #
      # Commands are grouped under their declared aggregate. Unassigned commands
      # (no aggregate metadata) are placed on the first aggregate or "Default".
      # Policies are assigned to the aggregate owning their trigger command.
      #
      # @param elements [Array<Parser::ParsedElement>] all parsed elements
      # @return [Hash<String, Hash>] mapping aggregate name to { commands: [...], policies: [...] }
      def group_by_aggregate(elements)
        aggregates = {}
        unassigned = []

        elements.each do |el|
          case el.type
          when :command
            agg_name = el.meta[:aggregate]
            if agg_name
              aggregates[agg_name] ||= { commands: [], policies: [] }
              aggregates[agg_name][:commands] << el
            else
              unassigned << el
            end
          when :policy
            trigger = el.meta[:trigger]
            agg_name = find_aggregate_for_trigger(elements, trigger)
            target = agg_name || aggregates.keys.first || "Default"
            aggregates[target] ||= { commands: [], policies: [] }
            aggregates[target][:policies] << el
          end
        end

        unless unassigned.empty?
          first = aggregates.keys.first || "Default"
          aggregates[first] ||= { commands: [], policies: [] }
          aggregates[first][:commands] = unassigned + aggregates[first][:commands]
        end

        aggregates
      end

      # Finds the aggregate that owns a given trigger command.
      #
      # @param elements [Array<Parser::ParsedElement>] all parsed elements
      # @param trigger_name [String] the command name to look up
      # @return [String, nil] the aggregate name, or nil if not found
      def find_aggregate_for_trigger(elements, trigger_name)
        elements.each do |el|
          next unless el.type == :command && el.name == trigger_name
          return el.meta[:aggregate] if el.meta[:aggregate]
        end
        nil
      end

      # Appends parser warnings as Ruby comments to the output lines.
      #
      # @param lines [Array<String>] the output lines array (mutated in place)
      # @return [void]
      def append_warnings(lines)
        @parse_result.warnings.each do |w|
          lines << "  # WARNING: #{w}"
        end
      end
    end
  end
end
