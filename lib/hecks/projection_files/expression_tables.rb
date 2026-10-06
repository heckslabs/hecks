# frozen_string_literal: true

module Hecks
  module ProjectionFiles
    # The expression-tables projection: the admitted operators, with the algebra each comparison
    # declares. Extended onto `ProjectionFiles`.
    module ExpressionTables
      # @param root [String] the checkout
      # @return [Result] `lib/hecks/bluebook/expression/projection.json`
      # @raise [Refused] if an admitted operator has no declared algebra, or the projection drops an
      #   operator the language's own guards evaluate through
      def expression_tables(root)
        require "hecks"
        require "hecks/grammar"
        operators = expression_operators(Grammar.expression)
        dropped = Grammar.self_bearing_operators.except(*operators.map { |row| row[:symbol] })
        raise Refused, dropped_message(dropped) unless dropped.empty?

        dispatcher = Grammar.expression
        text = "#{JSON.pretty_generate(operators: operators, normalisations: Grammar.admitted_normalisations(dispatcher))}\n"
        Result.new({ File.join(root, "lib/hecks/bluebook/expression/projection.json") => text }, [])
      end

      # @param dispatcher [Object] the expression dispatcher
      # @return [Array<Hash>] each admitted operator, with the algebra a comparison declares
      # @raise [Refused] if a comparison has no declared algebra
      def expression_operators(dispatcher)
        algebra = comparison_algebra
        Grammar.admitted_operators(dispatcher).map { |op| operator_row(op, algebra) }
      end

      # @return [Hash{String => Hash}] each comparison's declared algebra, by operator symbol
      def comparison_algebra
        vocabulary = chapter.aggregates.find { |aggregate| aggregate.name == "Vocabulary" }
        vocabulary.value_objects.find { |value_object| value_object.hecks_name == "Comparison" }
                  .members.to_h { |row| [row.to_h.values.first, row.to_h] }
      end

      # @param operator [Hash] one admitted operator
      # @param algebra [Hash{String => Hash}] each comparison's declared algebra
      # @return [Hash] the operator's projected row
      # @raise [Refused] if a comparison has no declared algebra
      def operator_row(operator, algebra)
        row = operator.slice(:symbol, :category, :precedence, :arity)
        return row unless operator[:category] == "comparison"

        declared = algebra.fetch(operator[:symbol]) do
          raise Refused, "#{operator[:symbol]} is admitted but Vocabulary::Comparison declares no algebra for it"
        end
        row.merge(compares_less_than: declared[:compares_less_than],
                  compares_equal: declared[:compares_equal], negated: declared[:negated])
      end

      # @param dropped [Hash{String => Array<String>}] operator to the guards evaluating through it
      # @return [String] one line for each operator a projection would strand
      def dropped_message(dropped)
        dropped.map do |symbol, sites|
          "#{symbol} is self-bearing — the language's own predicates evaluate through it " \
            "(#{sites.first(3).join("; ")}) — rewrite those guards before retiring it"
        end.join("\n")
      end
    end
  end
end
