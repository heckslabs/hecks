require "json"
require_relative "../../rendering"

module Hecksagain
  module Bluebook
    module Expression
      class EvaluationError < StandardError; end

      module Resolver
        SIGN_TESTS = %w[positive? negative? zero?].freeze

        # Which Comparison operator each sign test is sugar for, against the
        # literal 0 — declared the same way in Vocabulary::SignTest's
        # compares_via (language/bluebook.bluebook) ; spec/vocabulary_conformance_spec
        # holds the two tables equal.
        SIGN_TEST_OPERATORS = {
          "positive?" => ">",
          "negative?" => "<",
          "zero?"     => "=="
        }.freeze

        # The leaf grammar an expression's dotted/arithmetic side parses into.
        # Which node a string produces is a pure function of the string, so
        # parse() runs once per distinct leaf (folded into Evaluator's own
        # ast_cache — see evaluator.rb) and interpret() reads state/attrs
        # fresh on every call. Only Lookup — the true leaf — ever touches
        # state/attrs.
        IntegerLiteral = Struct.new(:value, keyword_init: true)
        FloatLiteral   = Struct.new(:value, keyword_init: true)
        StringLiteral  = Struct.new(:value, keyword_init: true)
        BoolLiteral    = Struct.new(:value, keyword_init: true)
        NilLiteral     = Struct.new(keyword_init: true)
        Addition       = Struct.new(:left, :right, keyword_init: true)
        SignTest       = Struct.new(:operator, :test, :receiver, keyword_init: true)
        Empty          = Struct.new(:receiver, keyword_init: true)
        ToS            = Struct.new(:receiver, keyword_init: true)
        Modulo         = Struct.new(:receiver, :divisor, keyword_init: true)
        Size           = Struct.new(:receiver, keyword_init: true)
        Lookup         = Struct.new(:path, keyword_init: true)

        module_function

        def resolve(expr, state, attrs)
          interpret(parse(expr), state, attrs)
        end

        def parse(expr)
          expr = expr.to_s.strip

          return Size.new(receiver: parse(Regexp.last_match(1))) if expr =~ /\A(.+)\.length\z/

          return IntegerLiteral.new(value: Integer(expr, 10)) if expr.match?(/\A-?\d+\z/)
          return FloatLiteral.new(value: Float(expr))         if expr.match?(/\A-?\d*\.\d+\z/)
          return StringLiteral.new(value: expr[1..-2])        if quoted?(expr)
          return BoolLiteral.new(value: true)                 if expr == "true"
          return BoolLiteral.new(value: false)                if expr == "false"
          return NilLiteral.new                                if expr == "nil"

          arithmetic = split_addition(expr)
          return Addition.new(left: parse(arithmetic[0]), right: parse(arithmetic[1])) if arithmetic

          sign = match_suffix(expr, SIGN_TESTS)
          return sign_test_node(sign) if sign

          return Empty.new(receiver: parse(Regexp.last_match(1))) if expr =~ /\A(.+)\.empty\?\z/
          return ToS.new(receiver: parse(Regexp.last_match(1)))   if expr =~ /\A(.+)\.to_s\z/

          modulo = match_call(expr, ".modulo(")
          return Modulo.new(receiver: parse(modulo[0]), divisor: parse(modulo[1])) if modulo

          return Size.new(receiver: parse(Regexp.last_match(1))) if expr =~ /\A(.+)\.size\z/

          Lookup.new(path: expr)
        end

        def sign_test_node(parts)
          receiver, test = parts
          symbol   = SIGN_TEST_OPERATORS.fetch(test)
          operator = Evaluator::OPERATORS.find { |candidate| candidate.symbol == symbol }
          SignTest.new(operator: operator, test: test, receiver: parse(receiver))
        end

        def interpret(node, state, attrs)
          case node
          when IntegerLiteral, FloatLiteral, StringLiteral, BoolLiteral then node.value
          when NilLiteral then nil
          when Addition
            add(interpret(node.left, state, attrs), interpret(node.right, state, attrs))
          when SignTest
            apply_sign_test(node, interpret(node.receiver, state, attrs))
          when Empty
            emptiness_of(interpret(node.receiver, state, attrs))
          when ToS
            string_of(interpret(node.receiver, state, attrs))
          when Modulo
            apply_modulo(interpret(node.receiver, state, attrs), interpret(node.divisor, state, attrs))
          when Size
            size_of(interpret(node.receiver, state, attrs))
          when Lookup
            lookup(node.path, state, attrs)
          end
        end

        def split_addition(expr)
          depth = 0
          quote = nil

          expr.each_char.with_index do |char, index|
            if quote
              quote = nil if char == quote
            elsif ['"', "'"].include?(char)
              quote = char
            elsif char == "("
              depth += 1
            elsif char == ")"
              depth -= 1
            elsif char == "+" && depth.zero?
              return [expr[0...index].strip, expr[(index + 1)..].strip]
            end
          end
          nil
        end

        def add(left, right)
          require_number(left, "addition") + require_number(right, "addition")
        end

        def quoted?(expr)
          return false if expr.length < 2

          (expr.start_with?('"') && expr.end_with?('"')) ||
            (expr.start_with?("'") && expr.end_with?("'"))
        end

        # Declared the same way in Vocabulary::SizedType
        # (language/bluebook.bluebook) — spec/vocabulary_conformance_spec
        # holds this equal to the language. Shared by .size and .empty?,
        # which admit the same set for the same reason.
        SIZED_TYPES = %w[Array String Hash].freeze

        def size_of(value)
          return value.size if value.is_a?(Array) || value.is_a?(String) || value.is_a?(Hash)

          raise EvaluationError, "size expects a list or string, got #{describe(value)}"
        end

        def emptiness_of(value)
          return value.empty? if value.is_a?(Array) || value.is_a?(String) || value.is_a?(Hash)

          raise EvaluationError, "empty? expects a list or string, got #{describe(value)}"
        end

        # Declared the same way in Vocabulary::ToStringType
        # (language/bluebook.bluebook) — spec/vocabulary_conformance_spec
        # holds this equal to the language.
        TO_STRING_TYPES = %w[String Integer Float TrueClass FalseClass NilClass].freeze

        def string_of(value)
          case value
          when String                then value
          when Integer, Float        then value.to_s
          when TrueClass, FalseClass then value.to_s
          when NilClass              then ""
          else
            raise EvaluationError, "to_s expects a scalar, got #{describe(value)}"
          end
        end

        def match_suffix(expr, suffixes)
          suffixes.each do |suffix|
            marker = ".#{suffix}"
            return [expr[0...-marker.length], suffix] if expr.end_with?(marker)
          end
          nil
        end

        def apply_sign_test(node, value)
          number = numeric(value)
          raise EvaluationError, "#{node.test} expects a number, got #{describe(value)}" unless number

          Evaluator.apply(node.operator, number, 0)
        end

        def match_call(expr, marker)
          index = expr.rindex(marker)
          return nil unless index && expr.end_with?(")")

          [expr[0...index], expr[(index + marker.length)...-1]]
        end

        def apply_modulo(receiver_value, divisor_value)
          divisor = require_number(divisor_value, "modulo")
          raise EvaluationError, "divided by 0" if divisor.zero?

          require_number(receiver_value, "modulo").to_i % divisor.to_i
        end

        def lookup(expr, state, attrs)
          return fetch(expr, state, attrs) unless expr.include?(".")

          head, *rest = expr.split(".")
          rest.reduce(fetch(head, state, attrs)) do |value, segment|
            break nil unless value.respond_to?(:[])

            value[segment.to_sym] || value[segment]
          end
        end

        def fetch(name, state, attrs)
          key = name.to_sym
          return attrs[key] if attrs.key?(key)
          return state[key] if known?(state, key)

          raise EvaluationError, "cannot resolve #{name.inspect} — no such attribute or argument"
        end

        def known?(state, key)
          return state.key?(key) if state.respond_to?(:key?)

          !state[key].nil?
        end

        def numeric(value)
          value if value.is_a?(Integer) || value.is_a?(Float)
        end

        def require_number(value, operation)
          numeric(value) ||
            raise(EvaluationError, "#{operation} expects a number, got #{describe(value)}")
        end

        def describe(value) = Rendering.describe(value)
      end
    end
  end
end
