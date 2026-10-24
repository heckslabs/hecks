module Hecks
  module Grammar
    # Says whether an expression can be compiled for a target dialect, read from the renderings the
    # admission ledger gives each admitted operator. Extended onto `Hecks::Grammar`.
    module Dialects
      # A lookup path a store can read: dotted identifiers, such as `owner.name`.
      READABLE_PATH = /\A[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*\z/

      # Says whether every operator a canonical expression evaluates through has a rendering for
      # `dialect`. Text the grammar does not recognise falls back to a lookup of that text, which
      # no store can read, so it is not compilable; a plain lookup or literal uses no operator and
      # compiles everywhere.
      #
      # @param canonical [String] canonical expression text, such as `"balance.positive?"`
      # @param dialect [String, Symbol] a rendering target, such as `"postgres"` or `"sqlite"`
      # @return [Boolean] true exactly when each operator used has a `dialect` rendering
      def compiles_for?(canonical, dialect)
        return false unless readable?(Bluebook::Expression::Evaluator.parse(canonical))

        rendered = operators_rendered_in(dialect)
        operators_in(canonical).all? { |symbol| rendered.include?(symbol) }
      end

      # The admitted operators that have a rendering for one dialect.
      #
      # @param dialect [String, Symbol] a rendering target, such as `"postgres"`
      # @return [Array<String>] each such operator's symbol, in admission order
      def operators_rendered_in(dialect)
        target = dialect.to_s
        renderings_by_operator.filter_map { |symbol, targets| symbol if targets.include?(target) }
      end

      # Every admitted operator with the targets it renders in, read once per process from the
      # replayed ledger.
      #
      # @return [Hash{String => Array<String>}] operator symbol to its rendering targets
      def renderings_by_operator
        @renderings_by_operator ||= admitted_operators.to_h do |operator|
          [operator[:symbol], operator[:renderings].map { |rendering| rendering[:target] }.uniq.freeze]
        end.freeze
      end

      private

      # Whether every lookup in a parsed node reads a plain dotted path.
      def readable?(node)
        case node
        when Bluebook::Expression::Resolver::Lookup then node.path.match?(READABLE_PATH)
        when Struct then node.to_a.all? { |member| readable?(member) }
        when Array then node.all? { |member| readable?(member) }
        else true
        end
      end
    end
  end
end
