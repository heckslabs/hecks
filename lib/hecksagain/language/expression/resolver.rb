# Resolver — the leaves of the sublanguage : one expression string to one value.
#
# The word SUBLANGUAGE is a claim, and the claim is that these expressions mean
# in the runtime exactly what they mean in Ruby. So the rules here are Ruby's,
# not a convenient approximation of them :
#
#   * a name that resolves to nothing RAISES, as an undefined name does in Ruby.
#     Answering nil would let a typo coerce to 0 and quietly satisfy a
#     predicate that should have failed loudly.
#   * `.positive?` on something that is not a number RAISES, as it does in Ruby.
#   * `.size` on something with no size RAISES, as it does in Ruby.
#
# Every rule has a twin in rust/src/interp_expr.rs, down to the wording of the
# errors — the parity harness compares refusals as carefully as successes, so a
# message that differs between runtimes is a difference someone has to explain
# away, and an explained-away difference is where a real one hides.
#
#   Resolver.resolve("toppings.size", state, attrs)   # => 2
module Hecksagain
  module Language
    module Expression
      # A predicate that cannot be evaluated is a defect, not a false.
      class EvaluationError < StandardError; end

      module Resolver
        SIGN_TESTS = %w[positive? negative? zero?].freeze

        module_function

        def resolve(expr, state, attrs)
          expr = expr.to_s.strip

          # `.length` is the Ruby-flavoured alias for `.size` — one operation.
          return resolve("#{Regexp.last_match(1)}.size", state, attrs) if expr =~ /\A(.+)\.length\z/

          return Integer(expr, 10) if expr.match?(/\A-?\d+\z/)
          return Float(expr)       if expr.match?(/\A-?\d*\.\d+\z/)
          return expr[1..-2]       if quoted?(expr)
          return true              if expr == "true"
          return false             if expr == "false"
          return nil               if expr == "nil"

          sign = match_suffix(expr, SIGN_TESTS)
          return apply_sign_test(sign, state, attrs) if sign

          modulo = match_call(expr, ".modulo(")
          return apply_modulo(modulo, state, attrs) if modulo

          return size_of(Regexp.last_match(1), state, attrs) if expr =~ /\A(.+)\.size\z/

          lookup(expr, state, attrs)
        end

        def quoted?(expr)
          return false if expr.length < 2

          (expr.start_with?('"') && expr.end_with?('"')) ||
            (expr.start_with?("'") && expr.end_with?("'"))
        end

        # Ruby raises NoMethodError for `nil.size` and returns a byte count for
        # `3.size`. Neither is a thing a predicate should be doing, so both are
        # refused by name.
        def size_of(receiver, state, attrs)
          value = resolve(receiver, state, attrs)
          return value.size if value.is_a?(Array) || value.is_a?(String) || value.is_a?(Hash)

          raise EvaluationError, "size expects a list or string, got #{describe(value)}"
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

        # `receiver.call(argument)` split into its two halves.
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

        # A flat name, or a dotted path stepping into value-object maps.
        def lookup(expr, state, attrs)
          return fetch(expr, state, attrs) unless expr.include?(".")

          head, *rest = expr.split(".")
          rest.reduce(fetch(head, state, attrs)) do |value, segment|
            break nil unless value.is_a?(Hash)

            value[segment.to_sym] || value[segment]
          end
        end

        # An unknown name RAISES. In Ruby an undefined name is a NameError, not a
        # nil ; a predicate that reads a misspelled attribute must fail loudly
        # rather than resolve to nothing and quietly refuse every valid command.
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

        # The numeric reading of a value, or nil when it has none. Ruby compares
        # 1 and 1.0 as equal, so both are numbers here ; a STRING is not, because
        # in Ruby 1 == "1" is false and this must agree.
        def numeric(value)
          value if value.is_a?(Integer) || value.is_a?(Float)
        end

        def require_number(value, operation)
          numeric(value) ||
            raise(EvaluationError, "#{operation} expects a number, got #{describe(value)}")
        end

        def describe(value)
          value.nil? ? "nil" : value.inspect
        end
      end
    end
  end
end
