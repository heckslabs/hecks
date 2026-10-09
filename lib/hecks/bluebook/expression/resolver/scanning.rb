# Text scanning for the `Resolver` leaf grammar: finding the split points of a leaf expression
# while skipping quoted literals and nested brackets.
module Hecks
  module Bluebook
    module Expression
      # Reopens `Resolver` (see resolver.rb) for its scanning helpers.
      module Resolver
        module_function

        # Quote characters a leaf expression may open a string literal with.
        QUOTES = ['"', "'"].freeze

        # How each bracket moves the nesting depth for a split on `+` or `,`. `{`/`}` and
        # `[`/`]` count like parens, so a `+` inside a block body or an array element is not this
        # expression's own addition.
        DEPTH_DELTA = { "(" => 1, "{" => 1, "[" => 1, ")" => -1, "}" => -1, "]" => -1 }.freeze

        # Walks `expr` from `start`, telling each character apart as quoted or plain.
        #
        # @param expr [String] the text to scan
        # @param start [Integer] the index to begin at, outside any quote
        # @yieldparam char [String] the character at `index`
        # @yieldparam index [Integer] its position in `expr`
        # @yieldparam plain [Boolean] false for a quote character or anything inside quotes
        # @return [void]
        def scan_text(expr, start = 0)
          quote = nil
          (start...expr.length).each do |index|
            char = expr[index]
            yield char, index, !quote && !QUOTES.include?(char)
            quote = next_quote(quote, char)
          end
        end

        # @param quote [String, nil] the quote character currently open, if any
        # @param char [String] the character just read
        # @return [String, nil] the quote character open after `char`
        def next_quote(quote, char)
          return (char == quote ? nil : quote) if quote

          char if QUOTES.include?(char)
        end

        # Splits a bracketed list into its element texts.
        #
        # @param expr [String] the leaf expression text
        # @return [Array<String>, nil] the non-empty elements, or `nil` when `expr` is not `[...]`
        def array_elements(expr)
          return nil unless expr.start_with?("[") && expr.end_with?("]")

          inner = expr[1..-2].strip
          return [] if inner.empty?

          split_at_commas(inner).reject(&:empty?)
        end

        # Splits `inner` at every comma outside quotes, parens and brackets.
        def split_at_commas(inner)
          elements = [+""]
          depth = 0
          scan_text(inner) do |char, _index, plain|
            depth += DEPTH_DELTA.fetch(char, 0) if plain && ["[", "]", "(", ")"].include?(char)
            top_level_comma = plain && char == "," && depth.zero?
            top_level_comma ? elements.push(+"") : elements.last << char
          end
          elements.map(&:strip)
        end

        # The text before and after the last top-level binary operator in `operators`, so a chain
        # splits left-associatively. A `-` is binary only after an operand (`a - b`, not `a - -b`
        # or a leading `-5`).
        #
        # @param operators [Array<String>] the single-character operators to split on
        # @return [Array<String>, nil] the operator and the texts either side, or `nil`
        def split_last_binary(expr, operators)
          depth = 0
          found = nil
          scan_text(expr) do |char, index, plain|
            next unless plain

            depth += DEPTH_DELTA.fetch(char, 0)
            found = index if depth.zero? && operators.include?(char) && binary_position?(expr, index, char)
          end
          found && [expr[found], expr[0...found].strip, expr[(found + 1)..].strip]
        end

        # Whether the operator at `index` has an operand on its left; only `-` can also be a sign.
        def binary_position?(expr, index, char)
          return true unless char == "-"

          expr[0...index].rstrip.match?(/[[:alnum:]_)\]"']\z/)
        end

        # Whether `expr` is one parenthesised group: its first `(` closes at its last character.
        def grouped?(expr)
          expr.start_with?("(") && matching_paren(expr, 1) == expr.length - 1
        end

        # Whether `expr` is wrapped in a matching pair of quotes.
        def quoted?(expr)
          return false if expr.length < 2

          (expr.start_with?('"') && expr.end_with?('"')) ||
            (expr.start_with?("'") && expr.end_with?("'"))
        end

        def match_suffix(expr, suffixes)
          suffixes.each do |suffix|
            marker = ".#{suffix}"
            return [expr[0...-marker.length], suffix] if expr.end_with?(marker)
          end
          nil
        end

        # Finds the outermost `marker` call whose matching `)` ends `expr`. `rindex` would split
        # nested `.modulo(` calls at the inner one, and a first match alone mis-parses chains.
        def match_call(expr, marker)
          start = 0
          while (index = expr.index(marker, start))
            close = matching_paren(expr, index + marker.length)
            return [expr[0...index], expr[(index + marker.length)...close]] if close == expr.length - 1

            start = index + 1
          end
          nil
        end

        # @param start [Integer] the index just after the opening `(`, where depth is 1
        # @return [Integer, nil] the index of the matching `)`, or `nil` if `expr` runs out first
        def matching_paren(expr, start) = matching_delimiter(expr, start, "(", ")")

        # The index of the `}` closing the `{` the caller's header match already consumed
        # (depth starts at 1). Quote-aware, so a `}` inside a quoted substring never counts.
        #
        # @param expr [String] the text to scan
        # @param start [Integer] the index just after the opening `{`, where depth is 1
        # @return [Integer, nil] the index of the matching `}`, or nil if `expr` runs
        #   out before depth returns to 0
        def matching_brace(expr, start) = matching_delimiter(expr, start, "{", "}")

        # @return [Integer, nil] the index of the `closer` that balances an already-open `opener`
        def matching_delimiter(expr, start, opener, closer)
          depth = 1
          scan_text(expr, start) do |char, index, plain|
            next unless plain

            depth += 1 if char == opener
            depth -= 1 if char == closer
            return index if depth.zero? && char == closer
          end
          nil
        end
      end
    end
  end
end
