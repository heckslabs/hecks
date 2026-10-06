module Hecks
  module Bluebook
    # The refusal each excluded regex construct answers with: its name and the reason it is refused.
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

      # Spelled out, not derived from the key: callers read these strings in refusals.
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

      module_function

      def refuse(key) = Rejection.new(CONSTRUCTS.fetch(key), REASONS.fetch(key))
    end
  end
end
