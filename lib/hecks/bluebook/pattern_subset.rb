require_relative "pattern_subset/scan"
require_relative "pattern_subset/refusals"

module Hecks
  module Bluebook
    # Which regexes a bluebook `pattern:` may say: only what every engine reads the same way.
    # Backtracking-only and ASCII/Unicode-dependent constructs are refused.
    module PatternSubset
      module_function

      # Returns nil when the pattern is admitted, a Rejection when it is not.
      #
      # One ordered character walk defines the subset; an escaped construct is a literal,
      # which is why each backslash pair is stepped over rather than matched as a whole.
      #
      # @param pattern [String, Symbol, #to_s] the declared `pattern:` regex source
      # @return [Rejection, nil] the reason the pattern is refused, or `nil` if admitted
      def validate(pattern)
        scan = Scan.new(pattern.to_s.chars)
        until scan.done?
          key = read_step(scan)
          return refuse(key) if key
        end
        nil
      end

      # Reads one construct, advancing `scan` past it.
      #
      # @return [Symbol, nil] the refusal key when the construct is outside the subset
      def read_step(scan)
        return escape_step(scan) if scan.char == "\\"
        return class_step(scan) if scan.in_class?
        return open_class_step(scan) if scan.char == "["

        plain_step(scan)
      end

      def escape_step(scan)
        nxt = scan.peek
        key = escape_refusal(nxt)
        scan.take(nxt ? 2 : 1) unless key
        key
      end

      def escape_refusal(nxt)
        return :backreference if nxt&.match?(/[1-9]/)
        return :named_backreference if %w[k g].include?(nxt)

        :perl_class if %w[d D w W s S].include?(nxt)
      end

      def class_step(scan)
        if scan.closing_bracket?
          scan.leave_class
          scan.take
          return nil
        end

        key = :posix_class if posix_class_at?(scan.chars, scan.index)
        scan.take
        key
      end

      def open_class_step(scan)
        return :posix_class if posix_class_at?(scan.chars, scan.index)

        scan.enter_class
        scan.take
        nil
      end

      def plain_step(scan)
        key = group_refusal(scan.chars, scan.index) || (:possessive if possessive_at?(scan.chars, scan.index))
        scan.take
        key
      end

      # @return [Symbol, nil] the refusal key for a `(?=`, `(?!`, `(?<=`, `(?<!` or `(?>` group
      def group_refusal(chars, index)
        return unless chars[index] == "(" && chars[index + 1] == "?"
        return :lookahead if %w[= !].include?(chars[index + 2])
        return :lookbehind if chars[index + 2] == "<" && %w[= !].include?(chars[index + 3])

        :atomic_group if chars[index + 2] == ">"
      end

      # How a line anchor is rewritten to a whole-string anchor.
      ANCHORS = { "^" => "\\A", "$" => "\\z" }.freeze

      # Rewrites the line anchors of a declared pattern into whole-string anchors.
      #
      # Ruby reads `^` and `$` as line anchors, so `"ok\n../evil"` satisfies `^[a-z]+$`; Rust's
      # `regex` reads them as text anchors. Enforcement matches the rewritten source so both
      # engines refuse the same values. Escaped characters and bracket classes are left alone.
      #
      # @param pattern [String, Symbol, #to_s] the declared `pattern:` regex source
      # @return [String] the source with `^` as `\A` and `$` as `\z` outside classes
      def whole_string(pattern)
        scan = Scan.new(pattern.to_s.chars)
        out = +""
        out << anchored(scan) until scan.done?
        out
      end

      # Reads one character (or an escaped pair) and answers what it becomes.
      def anchored(scan)
        return scan.take(2) if scan.char == "\\"

        if scan.in_class?
          scan.leave_class if scan.closing_bracket?
          scan.take
        elsif scan.char == "["
          scan.enter_class
          scan.take
        else
          ANCHORS.fetch(scan.char) { scan.char }.tap { scan.take }
        end
      end

      def posix_class_at?(chars, index)
        return false unless chars[index] == "[" && chars[index + 1] == ":"

        cursor = index + 2
        cursor += 1 while chars[cursor]&.match?(/[a-zA-Z]/)
        chars[cursor] == ":" && chars[cursor + 1] == "]"
      end

      # A possessive quantifier is `*+`, `++`, `?+` or a `{n,m}` bound followed by `+`.
      def possessive_at?(chars, index)
        return true if %w[* + ?].include?(chars[index]) && chars[index + 1] == "+"
        return false unless chars[index] == "{"

        len = bounded_quantifier_length(chars, index)
        !len.nil? && chars[index + len] == "+"
      end

      # Length of a `{n}` / `{n,}` / `{n,m}` bound at `index`, or nil if there is none.
      def bounded_quantifier_length(chars, index)
        cursor = skip_digits(chars, index + 1)
        return nil if cursor == index + 1

        cursor = skip_digits(chars, cursor + 1) if chars[cursor] == ","
        return nil unless chars[cursor] == "}"

        cursor - index + 1
      end

      def skip_digits(chars, cursor)
        cursor += 1 while chars[cursor]&.match?(/[0-9]/)
        cursor
      end
    end
  end
end
