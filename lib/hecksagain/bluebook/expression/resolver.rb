require "json"

module Hecksagain
  module Bluebook
    module Expression
      class EvaluationError < StandardError; end

      module Resolver
        SIGN_TESTS = %w[positive? negative? zero?].freeze

        module_function

        def resolve(expr, state, attrs)
          expr = expr.to_s.strip

          return resolve("#{Regexp.last_match(1)}.size", state, attrs) if expr =~ /\A(.+)\.length\z/

          return Integer(expr, 10) if expr.match?(/\A-?\d+\z/)
          return Float(expr)       if expr.match?(/\A-?\d*\.\d+\z/)
          return expr[1..-2]       if quoted?(expr)
        return true              if expr == "true"
        return false             if expr == "false"
        return nil               if expr == "nil"

        arithmetic = split_addition(expr)
        return add(arithmetic, state, attrs) if arithmetic

          sign = match_suffix(expr, SIGN_TESTS)
          return apply_sign_test(sign, state, attrs) if sign

          return emptiness_of(Regexp.last_match(1), state, attrs) if expr =~ /\A(.+)\.empty\?\z/
          return string_of(Regexp.last_match(1), state, attrs)    if expr =~ /\A(.+)\.to_s\z/

          modulo = match_call(expr, ".modulo(")
          return apply_modulo(modulo, state, attrs) if modulo

          return size_of(Regexp.last_match(1), state, attrs) if expr =~ /\A(.+)\.size\z/

        lookup(expr, state, attrs)
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

      def add(parts, state, attrs)
        left, right = parts
        require_number(resolve(left, state, attrs), "addition") +
          require_number(resolve(right, state, attrs), "addition")
      end

        def quoted?(expr)
          return false if expr.length < 2

          (expr.start_with?('"') && expr.end_with?('"')) ||
            (expr.start_with?("'") && expr.end_with?("'"))
        end

        def size_of(receiver, state, attrs)
          value = resolve(receiver, state, attrs)
          return value.size if value.is_a?(Array) || value.is_a?(String) || value.is_a?(Hash)

          raise EvaluationError, "size expects a list or string, got #{describe(value)}"
        end

        def emptiness_of(receiver, state, attrs)
          value = resolve(receiver, state, attrs)
          return value.empty? if value.is_a?(Array) || value.is_a?(String) || value.is_a?(Hash)

          raise EvaluationError, "empty? expects a list or string, got #{describe(value)}"
        end

        def string_of(receiver, state, attrs)
          value = resolve(receiver, state, attrs)

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

        def apply_sign_test(parts, state, attrs)
          receiver, test = parts
          value = resolve(receiver, state, attrs)
          number = numeric(value)
          raise EvaluationError, "#{test} expects a number, got #{describe(value)}" unless number

          case test
          when "positive?" then number.positive?
          when "negative?" then number.negative?
          else number.zero?
          end
        end

        def match_call(expr, marker)
          index = expr.rindex(marker)
          return nil unless index && expr.end_with?(")")

          [expr[0...index], expr[(index + marker.length)...-1]]
        end

        def apply_modulo(parts, state, attrs)
          receiver, argument = parts
          divisor = require_number(resolve(argument, state, attrs), "modulo")
          raise EvaluationError, "divided by 0" if divisor.zero?

          require_number(resolve(receiver, state, attrs), "modulo").to_i % divisor.to_i
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

        def describe(value)
          case value
          when nil then "nil"
          when Hash, Array then JSON.generate(value)
          else value.inspect
          end
        end
      end
    end
  end
end
