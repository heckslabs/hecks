require_relative "../resolver"

module Hecks
  module Bluebook
    module Expression
      module Evaluator
        # Finds the split points of a predicate's text: outermost parens, `||`/`&&`, comparison
        # operators and the `.include?(...)` call, skipping anything inside quotes or brackets.
        module Scanning
          module_function

          # Quote characters a predicate may open a string literal with.
          QUOTES = ['"', "'"].freeze

          # How each bracket moves the nesting depth. `{`/`}` and `[`/`]` count like parens: an
          # operator inside a block predicate (`.all? { |s| s.length > 0 }`) or an array literal
          # (`[0, 0 + 0]`) must not read as a split point for the enclosing expression.
          BRACKETS = { "(" => 1, "{" => 1, "[" => 1, ")" => -1, "}" => -1, "]" => -1 }.freeze

          # Tracks quote and bracket nesting while a predicate is read left to right.
          class Position
            def initialize
              @depth = 0
              @quote = nil
            end

            # Consumes the next character.
            #
            # @param char [String] the character at the current position
            # @return [Boolean] whether `char` sits at the top level, outside quotes and brackets
            def top_level?(char)
              if @quote
                @quote = nil if char == @quote
              elsif QUOTES.include?(char)
                @quote = char
              elsif BRACKETS.key?(char)
                @depth += BRACKETS.fetch(char)
              else
                return @depth.zero?
              end
              false
            end
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

          # Strips redundant outer parens, recursively.
          def strip_parens(expr)
            return expr unless wrapped_in_parens?(expr)

            strip_parens(expr[1..-2].strip)
          end

          # Whether one pair of parens spans the whole of `expr`.
          def wrapped_in_parens?(expr)
            return false unless expr.start_with?("(") && expr.end_with?(")")

            depth = 0
            closes_early = expr.each_char.with_index.any? do |char, index|
              depth += BRACKETS.fetch(char, 0) if ["(", ")"].include?(char)
              depth.zero? && index < expr.length - 1
            end
            !closes_early
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
            position = Position.new
            expr.each_char.with_index do |char, index|
              next unless position.top_level?(char) && expr[index, operator.length] == operator

              return index if !block_given? || yield(index)
            end
            nil
          end
        end
      end
    end
  end
end
