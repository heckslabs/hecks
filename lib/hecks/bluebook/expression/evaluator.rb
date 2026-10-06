require "json"
require_relative "../../vocabulary"
require_relative "evaluator/parser"

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
        def parse(expr) = Parser.parse(expr)

        # Interprets a parsed boolean/comparison node against `state`/`attrs`.
        def interpret(node, state, attrs)
          case node
          when Or  then interpret(node.left, state, attrs) || interpret(node.right, state, attrs)
          when And then interpret(node.left, state, attrs) && interpret(node.right, state, attrs)
          when Not then !interpret(node.node, state, attrs)
          else interpret_test(node, state, attrs)
          end
        end

        # Interprets a comparison, membership or bare-resolver node.
        def interpret_test(node, state, attrs)
          case node
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
      end
    end
  end
end
