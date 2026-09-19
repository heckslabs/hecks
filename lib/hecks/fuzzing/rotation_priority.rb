module Hecks
  module Fuzzing
    # The weighted half of `QualityControl::Target.Rotation`
    # (qa/bluebook/quality_control.bluebook) — see that query's own
    # comment for why the ledger itself still only offers
    # least-recently-swept order: `order_by` sorts by exactly one stored
    # field, and a target's actual rotation priority wants two blended
    # together (time since last swept, and recent yield), which nothing
    # in the query sublanguage can express. `Rotation` stays the raw
    # view; this module is where the blend actually happens, against the
    # rows that query already returns.
    #
    # ## Pure, deliberately
    #
    # Every method here is a function of its own arguments only — no clock
    # read, no query dispatched, nothing random — so this is unit-testable
    # with plain hashes and no ledger boot at all, and reruns identically
    # given the same rotation, the same `now` and the same dials. `now`
    # arrives as an argument for the exact reason `Target.Claim`'s own
    # comment already gives: a pure function cannot ask the time, so
    # whoever calls this supplies it, exactly as it supplies an id.
    #
    # ## Where this actually matters, and where it does not
    #
    # Checked against `bin/qa_sweep`'s own code, not assumed. `bin/qa_sweep
    # --all` sweeps every currently-waiting target in one pass, regardless
    # of order (`run_all_mode`'s own `waiting.map { spawn_sweep_child }` —
    # every element the query returned, never `.first`), so nothing about
    # this module's own ordering changes what `--all` does; it already
    # sweeps everything the ledger has to offer. What it changes is
    # `bin/qa_sweep` invoked with no target argument, which today picks
    # exactly one target via `Target.Rotation.first` — wiring `.pick` in
    # there instead is this module's one real caller, and (per the same
    # investigation) its only one: there is no separate scheduling or
    # concurrency-limit mechanism elsewhere in this repository for it to
    # feed instead.
    module RotationPriority
      module_function

      # The next stored `Target.yield_score` — decay what survives from
      # before, then add whatever this just-concluded period actually
      # found. Integer division, like every other count in this ledger
      # (`Sweep.CheckCount`, `Bug.BugOrder`): a yield score is a
      # priority signal, not a precise statistic, and a fractional score
      # would need a value object this ledger does not have.
      #
      # `decay_percent` defaults to the dial, not a literal, so a caller
      # that does not care still gets the practice's own current answer
      # to "how much of this is 'recent'" rather than a second, silently
      # drifting copy of the same number.
      #
      # @param old_score [Integer] the target's `Target.yield_score` before this period
      # @param surprises_this_period [Integer] how many Surprised checks this period found
      # @param decay_percent [Integer] percent of `old_score` that survives into the new
      #   score; defaults to `QualityControlDials::YIELD_DECAY_PERCENT`
      # @return [Integer] the next `Target.yield_score` to store
      # @raise [ArgumentError] if `old_score` is negative
      # @raise [ArgumentError] if `surprises_this_period` is negative
      def next_yield_score(old_score:, surprises_this_period:,
                           decay_percent: QualityControlDials::YIELD_DECAY_PERCENT)
        raise ArgumentError, "old_score must not be negative" if old_score.negative?
        raise ArgumentError, "surprises_this_period must not be negative" if surprises_this_period.negative?

        ((old_score * decay_percent) / 100) + surprises_this_period
      end

      # The pick itself. `rows` is whatever `Target.Rotation` returned —
      # each row a hash carrying at least `:last_swept` and
      # `:yield_score`, both `{ value: Integer }`, the shape every
      # VO-typed field in this ledger already comes back as. Returns
      # `nil` for an empty rotation, the same "nothing waiting" case
      # `bin/qa_sweep` already handles by seeding the default targets.
      #
      # The floor wins outright — no starvation, on purpose (see
      # `QualityControlDials::ROTATION_STALE_FLOOR_SECONDS`'s own
      # comment for why a floor and not a total exclusion). A row stale
      # past `floor_seconds` is picked ahead of every row that is not,
      # oldest-first among however many have crossed it — the same
      # tiebreak `Rotation` itself already uses for everything, which
      # keeps the floor from becoming a new source of starvation between
      # two long-neglected targets.
      #
      # Below the floor, highest combined score wins. `staleness +
      # (yield_score * weight_seconds)` — plain addition, never a ratio
      # or anything that could divide by zero, and the units are
      # deliberately the same (seconds) so `weight_seconds` reads as
      # "how many seconds of extra staleness one point of yield is
      # worth" rather than an opaque multiplier nobody could sanity
      # check by eye.
      #
      # @param rows [Array<Hash>] rows from `Target.Rotation`, each carrying at least
      #   `:last_swept` and `:yield_score` as `{ value: Integer }`
      # @param now [Integer] the current time, Unix epoch seconds
      # @param weight_seconds [Integer] seconds of extra staleness one point of yield is
      #   worth; defaults to `QualityControlDials::YIELD_WEIGHT_SECONDS`
      # @param floor_seconds [Integer] staleness, in seconds, past which a row is picked
      #   ahead of every row not yet that stale; defaults to
      #   `QualityControlDials::ROTATION_STALE_FLOOR_SECONDS`
      # @return [Hash, nil] the picked row, or `nil` if `rows` is empty
      def pick(rows, now:, weight_seconds: QualityControlDials::YIELD_WEIGHT_SECONDS,
               floor_seconds: QualityControlDials::ROTATION_STALE_FLOOR_SECONDS)
        return nil if rows.empty?

        floored = rows.select { |row| staleness(row, now) >= floor_seconds }
        return floored.min_by { |row| row[:last_swept][:value] } unless floored.empty?

        rows.max_by { |row| staleness(row, now) + (row[:yield_score][:value] * weight_seconds) }
      end

      def staleness(row, now) = now - row[:last_swept][:value]
      private_class_method :staleness
    end
  end
end
