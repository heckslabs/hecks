require "json"
require_relative "../../rendering"
require_relative "../../vocabulary"
require_relative "resolver/block_predicates"

module Hecks
  module Bluebook
    module Expression
      class EvaluationError < StandardError; end

      # The dotted/arithmetic leaf grammar a predicate's `Resolve` node bottoms out in.
      # `parse` is a pure function of its string; `interpret` reads state/attrs fresh.
      module Resolver
        SIGN_TESTS = Hecks::Vocabulary.fetch("SignTest")

        # Comparison operator each sign test stands for, against the literal 0.
        SIGN_TEST_OPERATORS = Hecks::Vocabulary.rows("SignTest")
                                               .to_h { |row| [row["name"], row["compares_via"]] }
                                               .freeze

        # Leaf nodes of the grammar. Only Lookup touches state/attrs.
        IntegerLiteral = Struct.new(:value, keyword_init: true)
        FloatLiteral   = Struct.new(:value, keyword_init: true)
        StringLiteral  = Struct.new(:value, keyword_init: true)
        BoolLiteral    = Struct.new(:value, keyword_init: true)
        ArrayLiteral   = Struct.new(:elements, keyword_init: true)
        # A plain class: `Struct.new(keyword_init: true)` with no members raises on Ruby 3.2.
        NilLiteral     = Class.new
        Addition       = Struct.new(:left, :right, keyword_init: true)
        Subtraction    = Struct.new(:left, :right, keyword_init: true)
        Multiplication = Struct.new(:left, :right, keyword_init: true)
        # Integer operands divide with floor semantics (toward negative infinity); a zero divisor
        # is an evaluation fault, never a crash or an infinity.
        Division       = Struct.new(:left, :right, keyword_init: true)
        SignTest       = Struct.new(:operator, :test, :receiver, keyword_init: true)
        Empty          = Struct.new(:receiver, keyword_init: true)
        ToS            = Struct.new(:receiver, keyword_init: true)
        Modulo         = Struct.new(:receiver, :divisor, keyword_init: true)
        Size           = Struct.new(:receiver, keyword_init: true)
        Lookup         = Struct.new(:path, keyword_init: true)

        MatchesRegex   = Struct.new(:receiver, :pattern, :flags, keyword_init: true)

        Presence       = Struct.new(:receiver, :negated, keyword_init: true)

        # `.set?`/`.unset?` ask only `!nil?`; unlike `.blank?`, an assigned empty value is set.
        Assignment     = Struct.new(:receiver, :negated, keyword_init: true)

        Split          = Struct.new(:receiver, :separator, keyword_init: true)

        # `.strip`/`.lstrip`/`.rstrip`: `side` is `:both`, `:left` or `:right`. Strips Ruby's own
        # whitespace set (null, tab, line feed, vertical tab, form feed, carriage return, space),
        # never Unicode spaces; a receiver that is not a String is an evaluation fault.
        Strip          = Struct.new(:receiver, :side, keyword_init: true)

        Last           = Struct.new(:receiver, keyword_init: true)

        First          = Struct.new(:receiver, keyword_init: true)

        StartsWith = Struct.new(:receiver, :substring, keyword_init: true)
        EndsWith   = Struct.new(:receiver, :substring, keyword_init: true)

        module_function

        # Parses and interprets `expr` in one step, bypassing `Evaluator`'s boolean grammar.
        #
        # @param expr [String] the dotted/arithmetic leaf expression
        # @param state [Hash{Symbol => Object}] stored attribute values
        # @param attrs [Hash{Symbol => Object}] call arguments, checked before `state`
        # @return [Object] the resolved Integer, Float, String, boolean, nil, or Array
        # @raise [EvaluationError] on an unknown name or a wrongly typed operand
        def resolve(expr, state, attrs)
          interpret(parse(expr), state, attrs)
        end

        # Evaluates a node `parse` produced against `state` and `attrs`.
        #
        # @return [Object] the value the node resolves to
        # @raise [EvaluationError] if the node type is unhandled or an operand is refused
        def interpret(node, state, attrs)
          case node
          when IntegerLiteral, FloatLiteral, StringLiteral, BoolLiteral then node.value
          when ArrayLiteral then node.elements.map { |element| interpret(element, state, attrs) }
          when NilLiteral then nil
          when Addition, Subtraction, Multiplication, Division then interpret_binary(node, state, attrs)
          when Lookup then lookup(node.path, state, attrs)
          else interpret_on_receiver(node, state, attrs)
          end
        end

        # Each arithmetic node and the operation that applies it to its two resolved operands.
        BINARY_OPERATIONS = { Addition => :add, Subtraction => :subtract, Multiplication => :multiply,
                              Division => :divide }.freeze

        def interpret_binary(node, state, attrs)
          operation = BINARY_OPERATIONS.find { |klass, _| node.is_a?(klass) }.last
          public_send(operation, interpret(node.left, state, attrs), interpret(node.right, state, attrs))
        end

        # Resolves the node's receiver, then applies the operation `RECEIVER_OPERATIONS` names.
        def interpret_on_receiver(node, state, attrs)
          _, operation = RECEIVER_OPERATIONS.find { |klass, _| node.is_a?(klass) }
          # A missing arm must raise; silently returning nil is the one wrong answer
          # this grammar never allows.
          raise EvaluationError, "no interpreter handles #{node.class} — add a case before parse can produce it" unless operation

          operation.call(node, interpret(node.receiver, state, attrs), state, attrs)
        end
      end
    end
  end
end

require_relative "resolver/scanning"
require_relative "resolver/lookups"
require_relative "resolver/parsing"
require_relative "resolver/values"
require_relative "resolver/operations"
