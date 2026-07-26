# Evaluator — one canonical expression string to one verdict.
#
# Mirrors rust/src/runtime/interp_givens.rs, including its SPLIT ORDER, which
# is the part that actually matters. Precedence here is not a detail of how the
# code happens to be written — it IS the semantics. `a || b && c` means
# `a || (b && c)` only because the splitter takes `||` first, so a runtime that
# split `&&` first would reach a different verdict on the same text and both
# would look correct in isolation.
#
# Lowest precedence outward :
#
#   ||   →   &&   →   .include?   →   >=  <=  <  >  ==  !=   →   leaves
#
#   Evaluator.call("toppings.size < 10", state, attrs)   # => true
module Hecksagain
  module Bluebook
    module Expression
      module Evaluator
        COMPARISONS = %w[>= <= < > == !=].freeze

        module_function

        def call(expr, state, attrs = {})
          expr = strip_parens(expr.to_s.strip)

          left, right = split_top_level(expr, "||")
          return call(left, state, attrs) || call(right, state, attrs) if left

          left, right = split_top_level(expr, "&&")
          return call(left, state, attrs) && call(right, state, attrs) if left

          membership = match_include(expr)
          return includes?(membership, state, attrs) if membership

          COMPARISONS.each do |operator|
            left, right = split_comparison(expr, operator)
            return compare(operator, left, right, state, attrs) if left
          end

          truthy?(Resolver.resolve(expr, state, attrs))
        end

        def compare(operator, left, right, state, attrs)
          lhs = Resolver.resolve(left, state, attrs)
          rhs = Resolver.resolve(right, state, attrs)

          case operator
          when ">=" then !less_than(lhs, rhs)
          when "<=" then less_than(lhs, rhs) || equal?(lhs, rhs)
          when "<"  then less_than(lhs, rhs)
          when ">"  then !less_than(lhs, rhs) && !equal?(lhs, rhs)
          when "==" then equal?(lhs, rhs)
          when "!=" then !equal?(lhs, rhs)
          end
        end

        # Ruby's rule, not a convenient approximation of it. Numbers order
        # against numbers and strings against strings ; anything else RAISES,
        # exactly as `"abc" < 3` raises in Ruby. Coercing through to_s would have
        # made "10" < "9" true and called it a comparison.
        def less_than(lhs, rhs)
          left  = Resolver.numeric(lhs)
          right = Resolver.numeric(rhs)
          return left < right if left && right
          return lhs < rhs    if lhs.is_a?(String) && rhs.is_a?(String)

          raise EvaluationError,
                "comparison of #{class_of(lhs)} with #{Resolver.describe(rhs)} failed"
        end

        # Ruby's equality: 1 == 1.0 is true, 1 == "1" is false. Comparing to_s
        # would have made the second one true — the kind of agreement between
        # runtimes that is worse than a disagreement, because both are wrong.
        def equal?(lhs, rhs)
          left  = Resolver.numeric(lhs)
          right = Resolver.numeric(rhs)
          return left == right if left && right

          lhs == rhs
        end

        # Ruby's truthiness: ONLY nil and false are falsy. 0 is true. "" is true.
        # An earlier reading of this treated both as false, so
        # `given { count }` fired when there were none — a predicate that read as
        # "when there are some" and meant the opposite.
        def truthy?(value)
          !value.nil? && value != false
        end

        def class_of(value)
          value.nil? ? "nil" : value.class.name
        end

        # `toppings.include?("Basil")` — membership over a list, or over a
        # comma-separated string, matching the Rust branch.
        def match_include(expr)
          index = expr.rindex(".include?(")
          return nil unless index && expr.end_with?(")")

          [expr[0...index], expr[(index + ".include?(".length)...-1]]
        end

        def includes?(parts, state, attrs)
          haystack, needle = parts
          wanted = Resolver.resolve(needle, state, attrs).to_s

          case (found = Resolver.resolve(haystack, state, attrs))
          when Array  then found.any? { |item| item.to_s == wanted }
          when String then found.split(",").any? { |item| item.strip == wanted }
          else false
          end
        end

        # Drop parens only when they wrap the WHOLE expression — `(a) && (b)`
        # must keep them or the split would lose a branch.
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

        # Split on an operator that sits outside every paren and quote.
        def split_top_level(expr, operator)
          index = top_level_index(expr, operator)
          return nil unless index

          [expr[0...index].strip, expr[(index + operator.length)..].strip]
        end

        # As above, but refuses a match that is really part of a longer operator
        # (`>` inside `>=`, `=` inside `==`), which would split the text in the
        # middle of a comparison and silently invert the verdict.
        def split_comparison(expr, operator)
          index = top_level_index(expr, operator) { |at| !part_of_longer?(expr, at, operator) }
          return nil unless index

          [expr[0...index].strip, expr[(index + operator.length)..].strip]
        end

        def part_of_longer?(expr, index, operator)
          after  = expr[index + operator.length]
          before = index.positive? ? expr[index - 1] : nil

          return true if after == "=" && !operator.end_with?("=")
          return true if ["<", ">", "!", "="].include?(before) && operator.start_with?("=")

          false
        end

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
            elsif char == "("
              depth += 1
            elsif char == ")"
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
