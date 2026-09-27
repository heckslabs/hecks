require "json"
require_relative "../../vocabulary"

module Hecks
  module Bluebook
    module Expression
      # Parses a canonical predicate string into an Or/And/Not/Compare/Include/Resolve AST
      # and interprets it against a call's state/attrs; leaves delegate to `Resolver`.
      module Evaluator
        Operator = Struct.new(:symbol, :compares_less_than, :compares_equal, :negated, keyword_init: true)

        # Six comparison operators reduced to two primitives (less_than, equal).
        # Read from the checked-in projection because the evaluator runs while the chapter boots.
        # Freshness: spec/operators_export_spec.rb; conformance: spec/operator_conformance_spec.rb.
        PROJECTION = JSON.parse(
          File.read(File.join(__dir__, "projection.json")), symbolize_names: true
        ).freeze

        OPERATORS = PROJECTION.fetch(:operators)
                              .select { |row| row[:category] == "comparison" }
                              .map { |row| Operator.new(**row.slice(:symbol, :compares_less_than, :compares_equal, :negated)) }
                              .freeze

        COMPARISONS = OPERATORS.map(&:symbol).freeze

        # Leaf nodes hold parsed Resolver ASTs; only the state/attrs read varies per call,
        # so the whole tree can be parsed once and cached.
        Or      = Struct.new(:left, :right, keyword_init: true)
        And     = Struct.new(:left, :right, keyword_init: true)
        Not     = Struct.new(:node, keyword_init: true)
        Compare = Struct.new(:operator, :left, :right, keyword_init: true)
        Include = Struct.new(:haystack, :needle, keyword_init: true)
        Resolve = Struct.new(:expr, keyword_init: true)

        module_function

        # Parsed AST per distinct predicate string, keyed by the exact string `call` receives.
        # Unsynchronized `||=`: racing threads at worst parse twice, never corrupt.
        #
        # @return [Hash{String => Object}] the process-wide parse cache
        def ast_cache = @ast_cache ||= {}

        # Parses `expr` (cached per distinct string) and interprets it
        # against `state`/`attrs`.
        #
        # @param expr [String] the canonical predicate text to evaluate
        # @param state [Hash{Symbol => Object}] the stored attribute values
        #   a `Resolve`/`Compare` leaf may resolve against
        # @param attrs [Hash{Symbol => Object}] the call's own argument
        #   values, checked before `state`
        # @return [Boolean] whether `expr` holds
        # @raise [EvaluationError] if `expr` resolves an unknown attribute
        #   or argument, or applies an operation to a value of the wrong
        #   type
        def call(expr, state, attrs = {})
          interpret(ast_cache[expr] ||= parse(expr), state, attrs)
        end

        # Evaluates a Given/Invariant by walking its structured `ast`, falling back to
        # parsing `canonical` when the rule has none. HECKS_EVAL=string forces the text path.
        #
        # @param rule [Bluebook::Given, Bluebook::Invariant] the rule to evaluate
        # @param state [Hash{Symbol => Object}] stored attribute values a `Resolve`/`Compare` leaf
        #   may resolve against
        # @param attrs [Hash{Symbol => Object}] the call's own argument values, checked
        #   before `state`
        # @return [Boolean] whether `rule` holds
        # @raise [EvaluationError] if `rule` resolves an unknown attribute/argument, or
        #   misapplies an operation
        def call_rule(rule, state, attrs = {})
          return call(rule.canonical, state, attrs) if ENV["HECKS_EVAL"] == "string"

          interpret(ast_cache[rule.canonical] ||= nodes_for(rule), state, attrs)
        end

        # Returns `rule`'s AST from its `ast` field, else parsed from `canonical`.
        def nodes_for(rule)
          rule.ast ? AstReader.read_predicate(rule.ast) : parse(rule.canonical)
        end

        # Renders a refused rule's two operands, for a refusal message.
        # Only a bare top-level `Compare` has one honest answer; anything else, or an
        # operand that fails to resolve, yields nil rather than raising.
        def comparison_detail(expr, state, attrs = {})
          node = ast_cache[expr] ||= parse(expr)
          return nil unless node.is_a?(Compare)

          lhs = Resolver.interpret(node.left, state, attrs)
          rhs = Resolver.interpret(node.right, state, attrs)
          "left: #{Resolver.describe(lhs)}, right: #{Resolver.describe(rhs)}"
        rescue EvaluationError
          nil
        end

        # Parses `expr`'s boolean/comparison grammar into an AST; leaves go to `Resolver.parse`.
        def parse(expr)
          expr = strip_parens(expr.to_s.strip)

          left, right = split_top_level(expr, "||")
          return Or.new(left: parse(left), right: parse(right)) if left

          left, right = split_top_level(expr, "&&")
          return And.new(left: parse(left), right: parse(right)) if left

          # `!` binds the whole remainder, so strip it before `match_include` runs;
          # otherwise `!names.include?(x)` would swallow the `!` into the haystack text.
          return Not.new(node: parse(Regexp.last_match(1))) if expr =~ /\A!(.+)\z/

          membership = match_include(expr)
          return Include.new(haystack: Resolver.parse(membership[0]), needle: Resolver.parse(membership[1])) if membership

          OPERATORS.each do |op|
            left, right = split_comparison(expr, op.symbol)
            return Compare.new(operator: op, left: Resolver.parse(left), right: Resolver.parse(right)) if left
          end

          Resolve.new(expr: Resolver.parse(expr))
        end

        # Interprets a parsed boolean/comparison node against `state`/`attrs`.
        def interpret(node, state, attrs)
          case node
          when Or      then interpret(node.left, state, attrs) || interpret(node.right, state, attrs)
          when And     then interpret(node.left, state, attrs) && interpret(node.right, state, attrs)
          when Not     then !interpret(node.node, state, attrs)
          when Compare then compare(node.operator, node.left, node.right, state, attrs)
          when Include then includes?([node.haystack, node.needle], state, attrs)
          when Resolve then truthy?(Resolver.interpret(node.expr, state, attrs))
          else
            # Backstop: a missing arm would return nil, which Or/And read as an ordinary
            # false instead of "cannot evaluate".
            raise EvaluationError, "no interpreter handles #{node.class} — add a case before parse can produce it"
          end
        end

        # Resolves `left`/`right` and applies `comparator` to the results.
        def compare(comparator, left, right, state, attrs)
          lhs = Resolver.interpret(left, state, attrs)
          rhs = Resolver.interpret(right, state, attrs)

          apply(comparator, lhs, rhs)
        end

        # Applies the operator algebra to resolved values; SignTest reuses it against 0.
        def apply(comparator, lhs, rhs)
          result = (comparator.compares_less_than && less_than(lhs, rhs)) ||
                   (comparator.compares_equal && equal?(lhs, rhs))
          comparator.negated ? !result : result
        end

        # The `<` primitive: numeric if both numeric, lexical if both String.
        def less_than(lhs, rhs)
          left  = Resolver.numeric(lhs)
          right = Resolver.numeric(rhs)
          return left < right if left && right
          return lhs < rhs    if lhs.is_a?(String) && rhs.is_a?(String)

          raise EvaluationError,
                "comparison of #{class_of(lhs)} with #{Resolver.describe(rhs)} failed"
        end

        # The `equal` primitive: numeric if both numeric, `==` otherwise.
        def equal?(lhs, rhs)
          left  = Resolver.numeric(lhs)
          right = Resolver.numeric(rhs)
          return left == right if left && right

          lhs == rhs
        end

        # Ruby truthiness for a bare `Resolve` node.
        def truthy?(value)
          !value.nil? && value != false
        end

        # Names `value`'s class, for a refusal message.
        def class_of(value)
          value.nil? ? "nil" : value.class.name
        end

        # Splits `expr` at its outermost `.include?(...)` call, if any.
        # `rindex` would find an innermost call inside the needle, so try each occurrence left to
        # right and keep the first whose matching paren reaches the last character.
        def match_include(expr)
          start = 0
          marker = ".include?("
          while (index = expr.index(marker, start))
            close = Resolver.matching_paren(expr, index + marker.length)
            return [expr[0...index], expr[(index + marker.length)...close]] if close == expr.length - 1

            start = index + 1
          end
          nil
        end

        # Held equal to Vocabulary::IncludeHaystack by spec/vocabulary_conformance_spec.
        INCLUDE_HAYSTACKS = Hecks::Vocabulary.fetch("IncludeHaystack")

        # Resolves and evaluates an `Include` node's `.include?` test.
        def includes?(parts, state, attrs)
          haystack, needle = parts
          wanted = Resolver.interpret(needle, state, attrs)

          case (found = Resolver.interpret(haystack, state, attrs))
          when Array then found.any? { |item| equal?(item, wanted) }
          when String
            raise EvaluationError, "no implicit conversion of #{class_of(wanted)} into String" unless wanted.is_a?(String)

            found.include?(wanted)
          else false
          end
        end

        # Strips redundant outer parens, recursively.
        def strip_parens(expr)
          return expr unless expr.start_with?("(") && expr.end_with?(")")

          depth = 0
          expr.each_char.with_index do |char, index|
            depth += 1 if char == "("
            depth -= 1 if char == ")"
            return expr if depth.zero? && index < expr.length - 1
          end
          strip_parens(expr[1..-2].strip)
        end

        # Splits `expr` at its first top-level `operator`.
        def split_top_level(expr, operator)
          index = top_level_index(expr, operator)
          return nil unless index

          [expr[0...index].strip, expr[(index + operator.length)..].strip]
        end

        # Splits `expr` at its first top-level `operator` that is not part of a longer one
        # (`==` inside `===`, `<` in `<=`).
        def split_comparison(expr, operator)
          index = top_level_index(expr, operator) { |at| !part_of_longer?(expr, at, operator) }
          return nil unless index

          [expr[0...index].strip, expr[(index + operator.length)..].strip]
        end

        # Whether the `operator` at `index` is part of a longer operator's spelling.
        def part_of_longer?(expr, index, operator)
          after  = expr[index + operator.length]
          before = index.positive? ? expr[index - 1] : nil

          return true if after == "=" && !operator.end_with?("=")
          return true if ["<", ">", "!", "="].include?(before) && operator.start_with?("=")

          false
        end

        # Finds the first top-level occurrence of `operator`, tracking quotes and all bracket
        # kinds so an operator inside a call, block predicate or array literal is skipped.
        def top_level_index(expr, operator)
          depth = 0
          quote = nil
          index = 0

          while index < expr.length
            char = expr[index]

            if quote
              quote = nil if char == quote
            elsif ['"', "'"].include?(char)
              quote = char
            # `{`/`}` and `[`/`]` count toward depth like parens: an operator inside a
            # block predicate (`.all? { |s| s.length > 0 }`) or array literal (`[0, 0 + 0]`)
            # must not read as a split point for the enclosing expression.
            elsif ["(", "{", "["].include?(char)
              depth += 1
            elsif [")", "}", "]"].include?(char)
              depth -= 1
            elsif depth.zero? && expr[index, operator.length] == operator
              return index if !block_given? || yield(index)
            end

            index += 1
          end
          nil
        end
      end
    end
  end
end
