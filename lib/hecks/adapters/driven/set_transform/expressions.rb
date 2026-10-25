require_relative "../../../bluebook/expression"
require_relative "../../../naming"
require_relative "../../../runtime/scalar_field"

module Hecks
  module Adapters
    module SetTransform
      # Raised while compiling, before anything is written, when an expression or a write has no
      # SQL form that means what Ruby means by it.
      class Uncompilable < StandardError; end

      # One compiled operand: its SQL text and the type Ruby would hold it as (`:integer`,
      # `:float`, `:string`, or `:null` for a literal nil).
      Operand = Struct.new(:sql, :type)

      # What one statement collects while it compiles: the binds in placeholder order, the guards
      # every updated row must also meet, and the command's arguments an expression reads.
      Build = Struct.new(:binds, :guards, :arguments)

      # Compiles a parsed bluebook expression to SQL in the including adapter's dialect. Every
      # column an ordering comparison, an arithmetic operator or a sign test reads gets an
      # `IS NOT NULL` guard, and every integer result the dialect's integer guard, so a row where
      # Ruby would fault is never updated: the statement skips it and Ruby decides.
      module Expressions
        EVALUATOR = Bluebook::Expression::Evaluator
        RESOLVER  = Bluebook::Expression::Resolver
        ORDERING  = %w[< > <= >=].freeze
        NUMERIC   = %i[integer float].freeze
        SIGN_TESTS = { "positive?" => "> 0", "negative?" => "< 0", "zero?" => "= 0" }.freeze
        ARITHMETIC = { RESOLVER::Addition => "+", RESOLVER::Subtraction => "-", RESOLVER::Multiplication => "*" }.freeze

        private

        def predicate_sql(node, build)
          case node
          when EVALUATOR::Or  then "(#{predicate_sql(node.left, build)} OR #{predicate_sql(node.right, build)})"
          when EVALUATOR::And then "(#{predicate_sql(node.left, build)} AND #{predicate_sql(node.right, build)})"
          when EVALUATOR::Not then "(NOT #{predicate_sql(node.node, build)})"
          when EVALUATOR::Compare then compare_sql(node, build)
          when EVALUATOR::Resolve then test_sql(node.expr, build)
          else uncompilable(node)
          end
        end

        def compare_sql(node, build)
          symbol = node.operator_symbol
          ordering = ORDERING.include?(symbol)
          left, right = [node.left, node.right].map { |side| value_sql(side, build, strict: ordering) }
          return equality_sql(left, right, symbol, node) unless ordering

          uncompilable(node) unless ordered_pair?(left, right)
          "(#{ordered_text(left)} #{symbol} #{ordered_text(right)})"
        end

        def equality_sql(left, right, symbol, node)
          uncompilable(node) unless %w[== !=].include?(symbol) && comparable?(left, right)
          null_safe_equality(left.sql, right.sql, negated: symbol == "!=")
        end

        def ordered_pair?(left, right)
          (NUMERIC.include?(left.type) && NUMERIC.include?(right.type)) || [left.type, right.type] == %i[string string]
        end

        def comparable?(left, right)
          left.type == :null || right.type == :null || ordered_pair?(left, right)
        end

        def ordered_text(operand) = operand.type == :string ? text_ordering(operand.sql) : operand.sql

        def test_sql(node, build)
          case node
          when RESOLVER::SignTest then sign_test_sql(node, build)
          when RESOLVER::Assignment
            "(#{value_sql(node.receiver, build, strict: false).sql} IS #{"NOT " unless node.negated}NULL)"
          else uncompilable(node)
          end
        end

        def sign_test_sql(node, build)
          receiver = value_sql(node.receiver, build, strict: true)
          uncompilable(node) unless NUMERIC.include?(receiver.type) && SIGN_TESTS.key?(node.test)
          "(#{receiver.sql} #{SIGN_TESTS.fetch(node.test)})"
        end

        def value_sql(node, build, strict:)
          case node
          when RESOLVER::IntegerLiteral, RESOLVER::FloatLiteral, RESOLVER::StringLiteral then scalar_bind(node.value, build)
          when RESOLVER::NilLiteral then strict ? uncompilable(node) : Operand.new("NULL", :null)
          when RESOLVER::Lookup then lookup_sql(node, build, strict)
          when *ARITHMETIC.keys then arithmetic_sql(node, build)
          else uncompilable(node)
          end
        end

        # An argument is read before a field of the same name, as Ruby reads it.
        def lookup_sql(node, build, strict)
          name = node.path.to_sym
          return argument_sql(build.arguments[name], build, strict, node) if build.arguments.key?(name)

          field = Runtime::ScalarField.of(@aggregate, node.path) || uncompilable(node)
          operand = Operand.new(field_read(field), field.type)
          build.guards << "#{operand.sql} IS NOT NULL" if strict
          operand
        end

        def argument_sql(value, build, strict, node)
          return Operand.new("NULL", :null) if value.nil? && !strict

          scalar_bind(value, build) || uncompilable(node)
        end

        def arithmetic_sql(node, build)
          left, right = [node.left, node.right].map { |side| value_sql(side, build, strict: true) }
          uncompilable(node) unless [left.type, right.type] == %i[integer integer]

          sql = "(#{left.sql} #{ARITHMETIC.fetch(node.class)} #{right.sql})"
          guard = integer_guard(sql)
          build.guards << guard if guard
          Operand.new(sql, :integer)
        end

        # A bound literal or argument, typed by the Ruby value it holds; nil for any other value.
        def scalar_bind(value, build)
          type = { Integer => :integer, Float => :float, String => :string }.find { |klass, _| value.is_a?(klass) }&.last
          type && Operand.new(typed_placeholder(build.binds, value, type), type)
        end

        def field_read(field)
          field.lifecycle? ? quote_ident(field.name) : scalar_read(field.name, field.member, field.type)
        end

        def uncompilable(node)
          raise Uncompilable, "#{dialect_name} has no set-transform form for #{Naming.demodulise(node.class)}"
        end
      end
    end
  end
end
