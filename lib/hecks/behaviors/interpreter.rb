# Hecks::Behaviors::Interpreter
#
# Evaluates given expressions and applies mutations against an
# AggregateState. Mirrors hecks_life/src/runtime/interpreter.rs
# exactly so the Ruby and Rust runners agree on every test.
#
# Operators supported (highest → lowest precedence):
#   field.any?, field.empty?    Ruby idioms
#   ==, !=, >=, <=, >, <        comparisons
#   &&, ||                      boolean (top-level split, && binds tighter)
#
# Mutation values resolve symbols (`:attr`) from attrs then state,
# numbers as Int, quoted strings, true/false, [] / [a, b, c] as List,
# {k: v} as Map. Anything else falls through to Str.
#
#   Interpreter.check_givens(cmd, state, attrs)
#   Interpreter.apply_mutations(cmd, state, attrs)
require_relative "value"

module Hecks
  module Behaviors
    module Interpreter
      module_function

      def check_givens(cmd, state, attrs)
        cmd.givens.each do |g|
          next if evaluate_given(g.expression, state, attrs)
          msg = (g.respond_to?(:message) && g.message) || g.expression
          raise GivenFailed.new(msg, g.expression)
        end
      end

      def apply_mutations(cmd, state, attrs)
        cmd.mutations.each do |m|
          op = m.operation.to_sym
          val = resolve_native_value(m.value, attrs, state)
          case op
          when :set       then state.set(m.field, val)
          when :append    then state.append(m.field, val)
          when :increment then increment_field(state, m.field, val)
          when :decrement then increment_field(state, m.field, val, sign: -1)
          when :toggle    then state.toggle(m.field)
          end
        end
      end

      # Float-aware increment/decrement so `then_set :fatigue,
      # increment: 0.01` actually adds 0.01 (rather than rounding to 1
      # via `.to_i`). Mirrors hecks_life/src/runtime/aggregate_state.rs
      # increment_float.
      def increment_field(state, field, val, sign: 1)
        amount = val.numeric || 1
        if amount.to_i.to_f == amount
          state.increment(field, amount.to_i * sign)
        else
          state.increment_float(field, amount * sign)
        end
      end

      # Ruby IR preserves mutation value types: Symbol → attr ref,
      # String → literal, Integer/Float/Bool/Array/Hash → literal.
      # Falls through to string-form resolution for anything stringy
      # (Rust IR carries source tokens like "\"literal\"" / ":attr").
      def resolve_native_value(value, attrs, state)
        case value
        when Symbol
          v = attrs[value.to_s] || attrs[value] || state.fields[value.to_s]
          return v.is_a?(Value) ? v : Value.from(v)
        when String
          # Could be a Rust-style source token (`":foo"`, `"\"x\""`)
          # OR a Ruby string literal. Source tokens start with `:` /
          # `"` / `[` / `{` — fall through to string-form resolver.
          stripped = value.strip
          if stripped.start_with?(':', '"', '[', '{')
            return resolve_mutation_value(value, attrs, state)
          end
          # Bare numeric/bool sneaking in as String — let str-form handle.
          return resolve_mutation_value(value, attrs, state) if %w[true false].include?(stripped) ||
                                                                Integer(stripped, exception: false) ||
                                                                Float(stripped, exception: false)
          # Otherwise: literal string.
          Value.from(value)
        when Integer, Float, TrueClass, FalseClass, NilClass
          Value.from(value)
        when Array
          Value.list(value)
        when Hash
          Value.from(value)
        else
          Value.from(value.to_s)
        end
      end

      def evaluate_given(expr, state, attrs)
        expr = expr.to_s.strip
        # Boolean operators — split lowest precedence first.
        if (parts = split_top_level(expr, "||"))
          return evaluate_given(parts[0], state, attrs) || evaluate_given(parts[1], state, attrs)
        end
        if (parts = split_top_level(expr, "&&"))
          return evaluate_given(parts[0], state, attrs) && evaluate_given(parts[1], state, attrs)
        end
        # Ruby idioms: any?/empty? rewrite to size comparisons.
        if expr.end_with?(".any?")
          field = expr[0..-6].strip
          return Value.lt?(Value.from(0), resolve_expr("#{field}.size", state, attrs))
        end
        if expr.end_with?(".empty?")
          field = expr[0..-8].strip
          return Value.equal?(resolve_expr("#{field}.size", state, attrs), Value.from(0))
        end
        # Comparisons — multi-char before single-char.
        %w[>= <= < > == !=].each do |op|
          parts = split_comparison(expr, op)
          next unless parts
          left  = resolve_expr(parts[0].strip, state, attrs)
          right = resolve_expr(parts[1].strip, state, attrs)
          case op
          when ">=" then return !Value.lt?(left, right)
          when "<=" then return !Value.lt?(right, left)
          when "<"  then return Value.lt?(left, right)
          when ">"  then return Value.lt?(right, left)
          when "==" then return Value.equal?(left, right)
          when "!=" then return !Value.equal?(left, right)
          end
        end
        true
      end

      def split_top_level(expr, op)
        in_str = false
        i = 0
        while i + op.length <= expr.length
          c = expr[i]
          in_str = !in_str if c == '"'
          if !in_str && expr[i, op.length] == op
            return [expr[0...i].strip, expr[(i + op.length)..].strip]
          end
          i += 1
        end
        nil
      end

      def split_comparison(expr, op)
        return nil if op == "<" && (expr.include?("<=") || expr.include?("<<"))
        return nil if op == ">" && (expr.include?(">=") || expr.include?(">>"))
        idx = expr.index(op)
        return nil unless idx
        [expr[0...idx], expr[(idx + op.length)..]]
      end

      def resolve_expr(expr, state, attrs)
        return Value.from(Integer(expr)) if Integer(expr, exception: false)
        if expr.start_with?('"') && expr.end_with?('"')
          return Value.from(expr[1..-2])
        end
        return Value.from(true)  if expr == "true"
        return Value.from(false) if expr == "false"
        # rand_below(N) — uniform random integer in [0, N). Mirrors the
        # Rust evaluator (hecks_life/src/runtime/interpreter.rs) so
        # `given { rand_below(N) == 0 }` evaluates the same in both
        # runners. HECKS_RAND_SEED env var overrides RNG for tests :
        # seed=0 makes the predicate fire (always returns 0) ; seed=k
        # always returns k % N.
        if expr.start_with?("rand_below(") && expr.end_with?(")")
          arg = expr[("rand_below(".length)..-2].strip
          arg_val = resolve_expr(arg, state, attrs)
          n = arg_val.numeric.to_i rescue 0
          return Value.from(0) if n <= 0
          if (seed = ENV["HECKS_RAND_SEED"]) && Integer(seed, exception: false)
            return Value.from(Integer(seed) % n)
          end
          return Value.from(rand(n))
        end
        if expr.end_with?(".size")
          field = expr[0...-5]
          val = attrs[field] || attrs[field.to_sym] || state.get(field)
          v = Value.from(val)
          return Value.from(v.list_size) if v.list?
          return Value.from(v.str_size)  if v.kind == :str
          return Value.from(0)
        end
        if (v = attrs[expr] || attrs[expr.to_sym])
          return Value.from(v)
        end
        Value.from(state.get(expr))
      end

      def resolve_mutation_value(expr, attrs, state)
        expr = expr.to_s.strip
        if expr.start_with?('{') && expr.end_with?('}')
          inner = expr[1..-2]
          map = {}
          inner.split(',').each do |pair|
            pair = pair.strip
            if (idx = pair.index(':'))
              key = pair[0...idx].strip.delete_prefix(':')
              ref = pair[(idx + 1)..].strip.delete_prefix(':')
              map[key] = attrs[ref] || attrs[ref.to_sym] || ref
            end
          end
          return Value.from(map)
        end
        if expr.start_with?(':')
          field = expr[1..]
          val = attrs[field] || attrs[field.to_sym] || state.fields[field]
          return val.is_a?(Value) ? val : Value.from(val)
        end
        return Value.from(Integer(expr)) if Integer(expr, exception: false)
        if expr.start_with?('"') && expr.end_with?('"')
          return Value.from(expr[1..-2])
        end
        if expr.start_with?('[') && expr.end_with?(']')
          inner = expr[1..-2].strip
          return Value.list([]) if inner.empty?
          items = inner.split(',').map { |item| resolve_mutation_value(item.strip, attrs, state) }
          return Value.new(:list, items)
        end
        return Value.from(true)  if expr == "true"
        return Value.from(false) if expr == "false"
        # Bare identifier — try attrs, fall through to literal string.
        val = attrs[expr] || attrs[expr.to_sym]
        return val.is_a?(Value) ? val : Value.from(val) if val
        Value.from(expr)
      end

      class GivenFailed < StandardError
        attr_reader :expression
        def initialize(message, expression)
          super(message)
          @expression = expression
        end
      end
    end
  end
end
