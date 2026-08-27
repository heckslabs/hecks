module Hecks
  module Bluebook
    # WHICH REGEXES A BLUEBOOK MAY SAY.
    #
    # A `pattern:` is a fact about a value, carried in a bluebook — declared
    # data, not Ruby code, so it must not lean on what any one engine happens
    # to accept. Regex engines disagree in two different ways :
    #
    #   ONLY A BACKTRACKING ENGINE CAN MATCH IT — lookahead, lookbehind,
    #   backreferences, atomic groups, possessive quantifiers. None of these
    #   can be matched in linear time, and linear-time engines refuse them
    #   outright. Refused here for the same reason.
    #
    #   EVERY ENGINE PARSES IT AND THEY MEAN DIFFERENT THINGS — the dangerous
    #   half, because nothing errors. `\d` `\w` `\s` are ASCII in some engines
    #   and Unicode in others ; `[:digit:]` and friends flip the same way in
    #   the other direction. Both families are refused, and a domain spells
    #   the range it means.
    #
    # What remains — explicit ranges, alternation, quantifiers, anchors,
    # groups — reads identically everywhere, with `^` and `$` as LINE anchors
    # (Ruby's reading). The evidence is spec/corpus/fixtures/patterns.json.
    module PatternSubset
      Rejection = Struct.new(:construct, :reason)

      REASONS = {
        backreference:
                             "backreferences cannot be matched in linear time and portable " \
                             "engines refuse them ; a declared pattern may not depend on one",
        named_backreference:
                             "a named backreference is still a backreference — it cannot be " \
                             "matched in linear time ; a declared pattern may not depend on one",
        perl_class:
                             "engines read it in OPPOSITE directions : ASCII in some and " \
                             "Unicode in others, so an Arabic-Indic digit satisfies one and not " \
                             "the other. Spell the range you mean — [0-9], [A-Za-z0-9_], [ \t] " \
                             "— which every engine reads the same way",
        posix_class:
                             "[:digit:] and friends flip between ASCII and Unicode across " \
                             "engines — the mirror of the perl classes, and wrong in the same " \
                             "way. Spell the range you mean",
        lookahead:
                             "lookahead cannot be matched in linear time and portable engines " \
                             "refuse it ; a declared pattern may not depend on it",
        lookbehind:
                             "lookbehind cannot be matched in linear time and portable engines " \
                             "refuse it ; a declared pattern may not depend on it",
        atomic_group:
                             "an atomic group is a backtracking-engine control knob — " \
                             "linear-time engines reject `(?>` as a syntax error",
        possessive:
                             "a possessive quantifier is a backtracking-engine control knob — " \
                             "linear-time engines reject it as a syntax error"
      }.freeze

      module_function

      # nil when the pattern is admitted, a Rejection when it is not.
      #
      # A CHARACTER WALK, deliberately plain : the subset is defined by this
      # walk, and a cleverer spelling would hide what it admits. An escaped
      # construct is a LITERAL, not a violation — `\(\?=` is the three
      # characters "(?=" and says nothing about lookahead — which is why this
      # steps over each backslash pair rather than matching the pattern as a
      # whole.
      def validate(pattern)
        chars = pattern.to_s.chars
        index = 0
        # A CHARACTER-CLASS INTERIOR IS A DIFFERENT ALPHABET : inside `[...]`,
        # `*`, `+`, `?`, `(`, `?` are literal characters, not quantifiers or
        # group syntax — `[*+]` means "a literal asterisk or plus". `]` is
        # only the class's close when it isn't the first character after `[`
        # or `[^` (where it is itself a literal, per POSIX bracket-expression
        # rules).
        in_class = false
        class_start = nil

        while index < chars.length
          if chars[index] == "\\"
            nxt = chars[index + 1]
            return refuse(:backreference)        if nxt&.match?(/[1-9]/)
            return refuse(:named_backreference)  if %w[k g].include?(nxt)
            return refuse(:perl_class)           if %w[d D w W s S].include?(nxt)

            index += nxt ? 2 : 1
            next
          end

          if in_class
            if chars[index] == "]" && index != class_start
              in_class = false
              index += 1
              next
            end

            return refuse(:posix_class) if posix_class_at?(chars, index)

            index += 1
            next
          end

          if chars[index] == "["
            return refuse(:posix_class) if posix_class_at?(chars, index)

            in_class = true
            class_start = index + 1
            class_start += 1 if chars[class_start] == "^"
            index += 1
            next
          end

          if chars[index] == "(" && chars[index + 1] == "?"
            return refuse(:lookahead)    if %w[= !].include?(chars[index + 2])
            return refuse(:lookbehind)   if chars[index + 2] == "<" && %w[= !].include?(chars[index + 3])
            return refuse(:atomic_group) if chars[index + 2] == ">"
          end

          return refuse(:possessive) if possessive_at?(chars, index)

          index += 1
        end

        nil
      end

      # SPELLED OUT, not derived from the key : these strings are the refusal
      # a caller reads.
      CONSTRUCTS = {
        backreference:       "backreference",
        named_backreference: "named backreference",
        perl_class:          "perl character class",
        posix_class:         "posix bracket class",
        lookahead:           "lookahead",
        lookbehind:          "lookbehind",
        atomic_group:        "atomic group",
        possessive:          "possessive quantifier"
      }.freeze

      def refuse(key) = Rejection.new(CONSTRUCTS.fetch(key), REASONS.fetch(key))

      def posix_class_at?(chars, index)
        return false unless chars[index] == "[" && chars[index + 1] == ":"

        cursor = index + 2
        cursor += 1 while chars[cursor]&.match?(/[a-zA-Z]/)
        chars[cursor] == ":" && chars[cursor + 1] == "]"
      end

      # A possessive quantifier is `*+`, `++`, `?+`, or a bounded `{n}`/{n,m}`
      # immediately followed by `+` — only checked OUTSIDE a character class,
      # where `*`, `+`, `?`, `{`, `}` are quantifier syntax rather than
      # literal characters.
      def possessive_at?(chars, index)
        return true if %w[* + ?].include?(chars[index]) && chars[index + 1] == "+"
        return false unless chars[index] == "{"

        len = bounded_quantifier_length(chars, index)
        !len.nil? && chars[index + len] == "+"
      end

      # Length of a `{n}` / `{n,}` / `{n,m}` bound starting at `index`, or nil
      # if what's there isn't one.
      def bounded_quantifier_length(chars, index)
        cursor = index + 1
        digit_seen = false

        while chars[cursor]&.match?(/[0-9]/)
          digit_seen = true
          cursor += 1
        end
        return nil unless digit_seen

        if chars[cursor] == ","
          cursor += 1
          cursor += 1 while chars[cursor]&.match?(/[0-9]/)
        end

        return nil unless chars[cursor] == "}"

        cursor - index + 1
      end
    end
  end
end
