# Resolver — the leaves of the sublanguage : one expression string to one value.
#
# Mirrors rust/src/runtime/interp_expr.rs and interp_expr_ops.rs in the Hecks
# runtime, operation for operation. Where that file resolves a literal, a
# `.size`, a `.modulo(n)`, or a dotted value-object path, this resolves the
# same one the same way — because the two runtimes have to agree, and they can
# only agree on rules that are written down twice identically or not at all.
#
# Input shadows state : a command attribute of the same name wins over the
# aggregate's stored value, matching `attrs.get(field).unwrap_or(state.get(...))`
# on the Rust side.
#
#   Resolver.resolve("toppings.size", state, attrs)   # => 2
module Hecksagain
  module Expression
    module Resolver
      module_function

      def resolve(expr, state, attrs)
        expr = expr.to_s.strip

        # `.length` is the Ruby-flavoured alias for `.size` — one operation,
        # normalised at extraction, tolerated here for hand-written text.
        return resolve("#{Regexp.last_match(1)}.size", state, attrs) if expr =~ /\A(.+)\.length\z/

        return Integer(expr, 10) if expr.match?(/\A-?\d+\z/)
        return Float(expr)       if expr.match?(/\A-?\d*\.\d+\z/)
        return expr[1..-2]       if quoted?(expr)
        return true              if expr == "true"
        return false             if expr == "false"
        return nil               if expr == "nil"

        modulo = match_modulo(expr)
        return apply_modulo(modulo, state, attrs) if modulo

        return size_of(resolve(Regexp.last_match(1), state, attrs)) if expr =~ /\A(.+)\.size\z/

        lookup(expr, state, attrs)
      end

      def quoted?(expr)
        (expr.start_with?('"') && expr.end_with?('"') && expr.length >= 2) ||
          (expr.start_with?("'") && expr.end_with?("'") && expr.length >= 2)
      end

      def size_of(value)
        case value
        when Array, String, Hash then value.size
        else 0
        end
      end

      # `tick.modulo(60)` — the periodic-cadence gate. A non-positive divisor
      # short-circuits to 0 rather than raising, mirroring the Rust guard :
      # in a daemon, firing every tick beats dying.
      def match_modulo(expr)
        index = expr.rindex(".modulo(")
        return nil unless index && expr.end_with?(")")

        [expr[0...index], expr[(index + ".modulo(".length)...-1]]
      end

      def apply_modulo(parts, state, attrs)
        receiver, argument = parts
        divisor = numeric(resolve(argument, state, attrs)).to_i
        return 0 if divisor <= 0

        numeric(resolve(receiver, state, attrs)).to_i % divisor
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

      def fetch(name, state, attrs)
        key = name.to_sym
        return attrs[key] if attrs.key?(key)

        state[key]
      end

      # The numeric reading of a value, or nil when it has none. A string that
      # looks like a number counts — the Rust side coerces Str through f64 in
      # every comparison, so this must too.
      def numeric(value)
        case value
        when Integer, Float then value
        when String         then Float(value, exception: false)
        end
      end
    end
  end
end
