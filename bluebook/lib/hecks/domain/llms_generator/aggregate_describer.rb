module Hecks
  class LlmsGenerator
    # Hecks::LlmsGenerator::AggregateDescriber
    #
    # Renders individual aggregate sections (attributes, value objects, commands,
    # queries, specifications, validations, invariants) as plain-text lines for
    # an llms.txt document.
    #
    #   class MyGenerator
    #     include AggregateDescriber
    #   end
    #
    module AggregateDescriber
      # Describe a single aggregate: attributes, commands, queries,
      # specifications, validations, invariants, and policies.
      #
      # @param agg [Hecks::DomainModel::Structure::Aggregate]
      # @return [Array<String>]
      def describe_aggregate(agg)
        lines = ["## Aggregate: #{agg.name}", ""]
        lines.concat(describe_attributes(agg))
        lines.concat(describe_value_objects(agg))
        lines.concat(describe_commands(agg))
        lines.concat(describe_queries(agg))
        lines.concat(describe_specifications(agg))
        lines.concat(describe_validations(agg))
        lines.concat(describe_invariants(agg))
        lines.concat(describe_aggregate_policies(agg))
        lines
      end

      private

      # @return [Array<String>]
      def describe_attributes(agg)
        attrs = agg.attributes
        return [] if attrs.empty?

        lines = ["### Attributes", ""]
        attrs.each { |attr| lines << "- #{attr.name}: #{Hecks::Utils.type_label(attr)}" }
        lines << ""
        lines
      end

      # @return [Array<String>]
      def describe_value_objects(agg)
        vos = agg.value_objects
        return [] if vos.empty?

        lines = ["### Value Objects", ""]
        vos.each do |vo|
          attrs = vo.attributes.map { |a| "#{a.name}: #{a.type}" }.join(", ")
          lines << "- #{vo.name} (#{attrs})"
        end
        lines << ""
        lines
      end

      # @return [Array<String>]
      def describe_commands(agg)
        cmds = agg.commands
        return [] if cmds.empty?

        events = agg.events
        lines = ["### Commands", ""]
        cmds.each_with_index do |cmd, i|
          lines << format_command(cmd, events[i])
          cmd.preconditions.each { |c| lines << "  Precondition: #{c.message}" }
          cmd.postconditions.each { |c| lines << "  Postcondition: #{c.message}" }
        end
        lines << ""
        lines
      end

      # @return [String]
      def format_command(cmd, event)
        params = cmd.attributes.map { |a| "#{a.name}: #{Hecks::Utils.type_label(a)}" }.join(", ")
        event_info = event ? " -> emits #{event.name}" : ""
        "- #{cmd.name}(#{params})#{event_info}"
      end

      # @return [Array<String>]
      def describe_queries(agg)
        queries = agg.queries
        return [] if queries.empty?

        lines = ["### Queries", ""]
        queries.each { |q| lines << "- #{q.name}" }
        lines << ""
        lines
      end

      # @return [Array<String>]
      def describe_specifications(agg)
        specs = agg.specifications
        return [] if specs.empty?

        lines = ["### Specifications", ""]
        specs.each { |s| lines << "- #{s.name}" }
        lines << ""
        lines
      end
    end
  end
end
