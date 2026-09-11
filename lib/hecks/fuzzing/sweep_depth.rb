module Hecks
  module Fuzzing
    # HOW HARD ONE SWEEP FUZZES, AS A FUNCTION OF `Target.clean_streak`
    # (qa/bluebook/quality_control.bluebook — that attribute's own comment
    # says what the streak means). The sibling of `RotationPriority`: the
    # ledger holds the number, `QualityControlDials::WIDENING_TIERS` holds
    # the policy, and this module is where the two meet — a pure function
    # of both, nothing else read.
    #
    # WHY THIS IS NOT IN `bin/qa_sweep` ANY MORE. It was — `WIDENING_TIERS`
    # and `widen_for_streak` lived at the top of that script, which meant
    # policy data lived in a script (unlike every other dial, which lives
    # in the bluebook a human edits and reviews) and duplicated itself as
    # prose in SKILL.md. Now the table is a dial, this is the one reader,
    # and `bin/qa_sweep` calls it the way it already calls
    # `RotationPriority.pick`.
    #
    # PURE, DELIBERATELY — the same discipline `RotationPriority` keeps:
    # same streak in, same `[seeds, steps]` out, every time, which is what
    # lets a human predict what a given sweep is about to do before it
    # runs one. `tiers:` defaults to the dial but is a plain argument, so
    # a unit spec can pass its own table with no ledger boot at all and a
    # `bin/qa_sweep` run against a ledger that declares no dials (an
    # isolated spec's own fixture) can fall back the same way it already
    # does for `ADVERSARIAL_FRACTION`.
    module SweepDepth
      module_function

      # THE FALLBACK TABLE, for a boot with no `QualityControlDials` at all
      # — the same shape and the same three rows the dial ships with, so a
      # dial-less ledger fuzzes exactly as a dialled one does by default.
      # Never read when the dial exists; `bin/qa_sweep` passes the dial in.
      DEFAULT_TIERS = [
        { upto: 4,               seeds: 10, steps: 25 },
        { upto: 19,              seeds: 25, steps: 50 },
        { upto: Float::INFINITY, seeds: 50, steps: 100 }
      ].freeze

      # `[seeds, steps]` for one streak. The first row whose `upto` the
      # streak does not exceed wins — rows are read in order, so the table
      # must be ascending, and the last row's `Float::INFINITY` is what
      # makes it the ceiling rather than a gap.
      def for_streak(streak, tiers: DEFAULT_TIERS)
        raise ArgumentError, "streak must not be negative" if streak.negative?

        tier = tiers.find { |row| streak <= row[:upto] }
        raise ArgumentError, "no tier covers a streak of #{streak} — the last row must be upto: Float::INFINITY" unless tier

        [tier[:seeds], tier[:steps]]
      end
    end
  end
end
