module Hecksagain
  module Bluebook
    # WHICH REGEXES A BLUEBOOK MAY SAY, and how the two runtimes read the ones it
    # admits.
    #
    # A `pattern:` is a fact about a value, so both runtimes have to reach the
    # same verdict about it. Ruby's Onigmo and Rust's regex crate do not agree by
    # default, and they disagree in two different ways :
    #
    #   CANNOT BOTH PARSE IT — lookahead, lookbehind, backreferences, atomic
    #   groups, possessive quantifiers. Ruby has them, Rust does not (most are
    #   impossible to match in linear time). Refused.
    #
    #   BOTH PARSE IT AND MEAN DIFFERENT THINGS — the dangerous half, because
    #   nothing errors. `\d` `\w` `\s` are ASCII in Ruby and Unicode in Rust ;
    #   `[:digit:]` and friends are the exact mirror, Unicode in Ruby and ASCII in
    #   Rust. Both families are refused, and a domain spells the range it means.
    #
    # What remains — explicit ranges, alternation, quantifiers, anchors, groups —
    # the two engines read identically once Rust is told to treat `^` and `$` as
    # LINE anchors, which is Ruby's reading. That alignment and this subset are
    # one design ; neither is sufficient alone. The evidence is
    # spec/parity/fixtures/patterns.json, which both runtimes answer to.
    module PatternSubset
      Rejection = Struct.new(:construct, :reason)

      REASONS = {
        backreference:
          "Rust's regex crate has no backreferences (they cannot be matched in " \
          "linear time) ; Ruby does, so the two engines would disagree",
        named_backreference:
          "Rust's regex crate has no backreferences ; Ruby does",
        perl_class:
          "the two engines read it in OPPOSITE directions : Ruby's are ASCII and " \
          "Rust's are Unicode, so an Arabic-Indic digit satisfies one and not the " \
          "other. Spell the range you mean — [0-9], [A-Za-z0-9_], [ \t] — which " \
          "both read the same way",
        posix_class:
          "Ruby reads [:digit:] and friends as UNICODE and Rust reads them as " \
          "ASCII — the mirror of the perl classes, and wrong in the same way. " \
          "Spell the range you mean",
        lookahead:
          "Rust's regex crate has no lookahead (it cannot be matched in linear " \
          "time) ; Ruby does, so the two engines would disagree",
        lookbehind:
          "Rust's regex crate has no lookbehind ; Ruby does",
        atomic_group:
          "Ruby-only : Rust's regex crate rejects `(?>` as a syntax error",
        possessive:
          "Ruby-only : Rust's regex crate rejects it as a syntax error"
      }.freeze

      module_function

      # nil when the pattern is admitted, a Rejection when it is not.
      #
      # A CHARACTER WALK, in the same order as the Rust side and deliberately in
      # the same shape : the two are read side by side when either changes, and a
      # cleverer Ruby spelling would make that impossible. An escaped construct is
      # a LITERAL, not a violation — `\(\?=` is the three characters "(?=" and says
      # nothing about lookahead — which is why this steps over each backslash pair
      # rather than matching the pattern as a whole.
      def validate(pattern)
        chars = pattern.to_s.chars
        index = 0

        while index < chars.length
          if chars[index] == "\\"
            nxt = chars[index + 1]
            return refuse(:backreference)        if nxt&.match?(/[1-9]/)
            return refuse(:named_backreference)  if %w[k g].include?(nxt)
            return refuse(:perl_class)           if %w[d D w W s S].include?(nxt)

            index += nxt ? 2 : 1
            next
          end

          if chars[index] == "(" && chars[index + 1] == "?"
            return refuse(:lookahead)    if %w[= !].include?(chars[index + 2])
            return refuse(:lookbehind)   if chars[index + 2] == "<" && %w[= !].include?(chars[index + 3])
            return refuse(:atomic_group) if chars[index + 2] == ">"
          end

          return refuse(:posix_class)  if posix_class_at?(chars, index)
          return refuse(:possessive)   if %w[* + ?].include?(chars[index]) && chars[index + 1] == "+"

          index += 1
        end

        nil
      end

      # SPELLED OUT, not derived from the key : these strings are the refusal a
      # caller reads, so they have to match the Rust side character for character.
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
    end
  end
end
