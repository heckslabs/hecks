require_relative "scanning"
require_relative "../resolver"

module Hecks
  module Bluebook
    module Expression
      module Evaluator
        # Turns a canonical predicate string into an `Or`/`And`/`Not`/`Include`/`Compare`/`Resolve`
        # AST, trying the loosest-binding form first.
        module Parser
          module_function

          # Parses `expr`'s boolean/comparison grammar into an AST; leaves go to `Resolver.parse`.
          #
          # @param expr [String] the canonical predicate text
          # @return [Object] the AST's root node
          def parse(expr)
            expr = Scanning.strip_parens(expr.to_s.strip)

            parse_logical(expr) || parse_not(expr) || parse_include(expr) || parse_comparison(expr) ||
              Resolve.new(expr: Resolver.parse(expr))
          end

          # @return [Or, And, nil] the node for a top-level `||`, else `&&`, or `nil`
          def parse_logical(expr)
            [["||", Or], ["&&", And]].each do |operator, klass|
              left, right = Scanning.split_top_level(expr, operator)
              return klass.new(left: parse(left), right: parse(right)) if left
            end
            nil
          end

          # `!` binds the whole remainder, so strip it before `parse_include` runs;
          # otherwise `!names.include?(x)` would swallow the `!` into the haystack text.
          #
          # @return [Not, nil] the negation of what follows a leading `!`, else `nil`
          def parse_not(expr)
            negated = expr.match(/\A!(.+)\z/)
            Not.new(node: parse(negated[1])) if negated
          end

          # @return [Include, nil] the node for a trailing `.include?(...)` call, else `nil`
          def parse_include(expr)
            membership = Scanning.match_include(expr)
            return unless membership

            Include.new(haystack: Resolver.parse(membership[0]), needle: Resolver.parse(membership[1]))
          end

          # @return [Compare, nil] the node for the first comparison that splits `expr`, or `nil`
          def parse_comparison(expr)
            OPERATORS.each do |op|
              left, right = Scanning.split_comparison(expr, op.symbol)
              return Compare.new(operator: op, left: Resolver.parse(left), right: Resolver.parse(right)) if left
            end
            nil
          end
        end
      end
    end
  end
end
