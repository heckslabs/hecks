# frozen_string_literal: true

module Hecks
  module Translation
    # Renders a composed edge as `.bluebook` text, the form the era gate and the audit read back.
    module ComposeRender
      module_function

      # The `.bluebook` text of one edge, with a comment naming the chain it composes.
      #
      # @param edge [Bluebook::Translation] the composed edge
      # @param labels [Array<String>] the shape labels the chain passes through, in order
      # @return [String] the text, ending in a newline
      def render(edge, labels: [])
        lines = [*comment_lines(labels), header(edge)]
        edge.aggregates.each { |aggregate| lines.concat(aggregate_lines(aggregate)) }
        edge.retired.each { |name| lines << "  retired #{name.inspect}" }
        lines << "end"
        "#{lines.join("\n")}\n"
      end

      def header(edge)
        "Hecks.data_translation #{edge.domain.inspect}, from: #{edge.from.inspect}, to: #{edge.to.inspect} do"
      end

      def comment_lines(labels)
        return [] if labels.empty?

        ["# Composed from the chain #{labels.join(" -> ")}: the rules of each step, carried into one edge."]
      end

      def aggregate_lines(aggregate)
        header = "  aggregate #{aggregate.name.inspect}"
        header += ", was: #{aggregate.was.inspect}" if aggregate.was
        ["#{header} do", *rule_lines(aggregate).map { |line| "    #{line}" }, "  end"]
      end

      # Each field rule as the line that declares it, in the order the bluebook reads.
      def rule_lines(aggregate)
        renames(aggregate) + moves(aggregate) + converts(aggregate) + drops(aggregate) +
          retypes(aggregate) + derives(aggregate) + backfills(aggregate)
      end

      def renames(aggregate)
        aggregate.renames.map { |old_name, new_name| "rename #{symbol(old_name)}, to: #{symbol(new_name)}" }
      end

      def moves(aggregate)
        aggregate.moves.map { |move| "move #{move.from.inspect}, to: #{move.to.inspect}" }
      end

      def converts(aggregate)
        aggregate.converts.map do |convert|
          "convert #{convert.from.inspect}, to: #{convert.to.inspect}, values: #{convert.values.inspect}"
        end
      end

      def drops(aggregate) = aggregate.drops.map { |path| "drop #{path.to_s.inspect}" }

      def retypes(aggregate)
        aggregate.retypes.map { |retype| "retype #{retype.from.inspect}, to: #{retype.to.inspect}" }
      end

      def derives(aggregate)
        aggregate.derives.map do |derive|
          "derive #{symbol(derive.to)}, as: #{derive.expression.to_s.inspect}"
        end
      end

      def backfills(aggregate)
        aggregate.backfills.map do |backfill|
          "backfill #{symbol(backfill.name)}, default: #{backfill.default.inspect}"
        end
      end

      def symbol(name) = ":#{name}"
    end
  end
end
