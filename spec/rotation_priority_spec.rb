require "spec_helper"
require "hecks/fuzzing"

# `Hecks::Fuzzing::RotationPriority`, PROVEN AS THE PURE FUNCTION IT IS —
# plain hashes standing in for `Target.Rotation` rows, no ledger boot, no
# Postgres, nothing throwaway to clean up afterward. Every dial this
# module reads is passed explicitly in every example here, on purpose:
# a unit spec for a pure function should not depend on load order
# deciding whether `QualityControlDials` happens to be defined yet
# (`spec/quality_control_spec.rb`'s own examples cover the real dials,
# against a real booted-from-Memory `Target.Rotation`).
RSpec.describe Hecks::Fuzzing::RotationPriority do
  def row(reference, last_swept:, yield_score:)
    { reference: { value: reference }, last_swept: { value: last_swept }, yield_score: { value: yield_score } }
  end

  # SIMULATES 200 IRREGULAR TICKS OF "PICK, THEN RELEASE" — every pick
  # resets the winner's own `last_swept` to `now`, exactly the way a
  # real `bin/qa_sweep` clean pass would. `state` maps a reference to
  # its own `{ last_swept:, yield_score: }`, mutated as the simulation
  # runs; callers pass a fresh `Hash` per call (`transform_values(&:dup)`
  # is not needed — a new literal per test is simplest and clearest).
  # Returns every `[now, picked_reference]` pair, in tick order.
  def simulate_ticks(state, weight_seconds:, floor_seconds:)
    now = 0
    picks = []

    200.times do
      now += 17 # irregular tick length — nothing here should depend on a round number
      rows = state.map { |ref, a| row(ref, last_swept: a[:last_swept], yield_score: a[:yield_score]) }
      picked_ref = described_class.pick(rows, now: now, weight_seconds: weight_seconds,
                                               floor_seconds: floor_seconds)[:reference][:value]
      state[picked_ref][:last_swept] = now
      picks << [now, picked_ref]
    end

    picks
  end

  describe ".next_yield_score" do
    it "decays the old score by the given percent, then adds this period's finds" do
      expect(described_class.next_yield_score(old_score: 10, surprises_this_period: 3, decay_percent: 50))
        .to eq(8) # (10 * 50 / 100) + 3
    end

    it "never regenerates a score for a clean period on its own — only decay applies" do
      expect(described_class.next_yield_score(old_score: 10, surprises_this_period: 0, decay_percent: 50))
        .to eq(5)
    end

    it "settles at zero once a target has been clean long enough" do
      score = 10
      5.times { score = described_class.next_yield_score(old_score: score, surprises_this_period: 0, decay_percent: 50) }

      expect(score).to eq(0)
    end

    it "never runs backward from a fresh target's own zero" do
      expect(described_class.next_yield_score(old_score: 0, surprises_this_period: 0, decay_percent: 50)).to eq(0)
    end

    it "refuses a negative old score" do
      expect { described_class.next_yield_score(old_score: -1, surprises_this_period: 0, decay_percent: 50) }
        .to raise_error(ArgumentError, /old_score/)
    end

    it "refuses a negative count of this period's own finds" do
      expect { described_class.next_yield_score(old_score: 0, surprises_this_period: -1, decay_percent: 50) }
        .to raise_error(ArgumentError, /surprises_this_period/)
    end
  end

  describe ".pick" do
    it "answers nil against an empty rotation" do
      expect(described_class.pick([], now: 1_000, weight_seconds: 100, floor_seconds: 10_000)).to be_nil
    end

    it "weights toward the target with recent higher yield, below the floor" do
      exhausted = row("pizzas", last_swept: 900, yield_score: 0)
      hot       = row("roster", last_swept: 950, yield_score: 6)

      # "roster" was swept MORE recently (less staleness) but keeps
      # finding things — BUG#7/#15/#16, per the practice's own roster.
      picked = described_class.pick([exhausted, hot], now: 1_000, weight_seconds: 100, floor_seconds: 100_000)

      expect(picked[:reference][:value]).to eq("roster")
    end

    it "still prefers plain staleness when nobody has any yield" do
      older   = row("banking", last_swept: 0,   yield_score: 0)
      younger = row("pizzas",  last_swept: 500, yield_score: 0)

      picked = described_class.pick([older, younger], now: 1_000, weight_seconds: 100, floor_seconds: 100_000)

      expect(picked[:reference][:value]).to eq("banking")
    end

    it "overrides yield outright once a target crosses the stale floor" do
      exhausted = row("pizzas", last_swept: 0,   yield_score: 0)
      hot       = row("roster", last_swept: 950, yield_score: 50)

      picked = described_class.pick([exhausted, hot], now: 1_000, weight_seconds: 100, floor_seconds: 900)

      expect(picked[:reference][:value]).to eq("pizzas")
    end

    it "breaks a tie among multiple floored targets by which is oldest" do
      oldest       = row("banking", last_swept: 0,   yield_score: 0)
      also_floored = row("pizzas",  last_swept: 50,  yield_score: 0)

      picked = described_class.pick([also_floored, oldest], now: 1_000, weight_seconds: 100, floor_seconds: 900)

      expect(picked[:reference][:value]).to eq("banking")
    end

    # THE NO-STARVATION GUARANTEE ITSELF — many simulated rotation
    # picks, real elapsed time between them, two targets that always
    # out-yield a third one that never finds anything at all.
    #
    # THE BOUND, NOT THE MECHANISM. It would be tempting to assert
    # "exhausted is only ever picked once the floor forces it" — but
    # that is not quite what the arithmetic guarantees, and asserting it
    # is what an earlier draft of this example got wrong: because
    # staleness itself is UNBOUNDED while "hot"/"warm" keep resetting
    # their own staleness to ~0 every time THEY win, "exhausted"'s plain
    # staleness can occasionally out-race a competitor's own bounded
    # ceiling (yield_score * weight_seconds) even before crossing the
    # floor. That is a feature, not a bug — it means the floor is a
    # ceiling on the wait, not the only thing preventing it from being
    # arbitrarily long. What every waiting target IS guaranteed is never
    # waiting MORE than `floor_seconds` — that is the one thing this
    # example actually needs to hold.
    it "never leaves a waiting target unswept for longer than the floor, whatever its yield" do
      floor_seconds  = 1_000
      weight_seconds = 50

      state = {
        "hot"       => { last_swept: 0, yield_score: 10 },
        "warm"      => { last_swept: 0, yield_score: 3 },
        "exhausted" => { last_swept: 0, yield_score: 0 }
      }

      picks = simulate_ticks(state, weight_seconds: weight_seconds, floor_seconds: floor_seconds)
      first_exhausted_pick = picks.find { |_now, ref| ref == "exhausted" }

      expect(first_exhausted_pick).not_to be_nil
      expect(first_exhausted_pick.first).to be <= floor_seconds
    end

    # THE FLOOR'S OWN REASON TO EXIST, ISOLATED FROM THE "NATURAL
    # CROSSOVER" ABOVE — a weight dial large enough that a competitor's
    # own bounded ceiling is far out of plain staleness's reach within
    # any ordinary run. Without a floor this genuinely leaves the
    # exhausted target unswept for the whole simulated window; with the
    # SAME oversized weight, the floor still bounds the wait exactly the
    # way the dial promises, independent of how the OTHER dial is tuned.
    it "bounds the wait on the floor alone, even when the weight dial would otherwise starve a target for a very long time" do
      weight_seconds = 100_000 # one point of yield now outweighs a huge amount of plain staleness
      fresh_state = -> { { "hot" => { last_swept: 0, yield_score: 10 }, "exhausted" => { last_swept: 0, yield_score: 0 } } }

      without_floor = simulate_ticks(fresh_state.call, weight_seconds: weight_seconds, floor_seconds: Float::INFINITY)
      expect(without_floor.map(&:last)).not_to include("exhausted")

      with_floor = simulate_ticks(fresh_state.call, weight_seconds: weight_seconds, floor_seconds: 1_000)
      first_exhausted_pick = with_floor.find { |_now, ref| ref == "exhausted" }

      expect(first_exhausted_pick).not_to be_nil
      # ONE TICK OF SLACK (17 seconds, `simulate_ticks`'s own irregular
      # step) — `now` can only land ON the floor exactly by coincidence,
      # so the real guarantee is "no more than one tick past it," not
      # "never a second over."
      expect(first_exhausted_pick.first).to be <= 1_017
    end
  end
end
