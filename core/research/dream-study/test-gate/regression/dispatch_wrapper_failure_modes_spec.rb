# dispatch_wrapper_failure_modes_spec.rb
#
# [antibody-exempt: dream-study Phase 0f regression — covers named
#  bug i207 ; lives next to Phase 0e dispatch wrapper coverage]
#
# Regression coverage for i207 — GivenFailed is not a real dispatch
# failure. The dispatch wrapper that the body shells inline (mindstream,
# pulse_organs, rem_branch, nrem_branch, consolidate) used to log
# GivenFailed as a Doctor concern, but a refused given is *design*,
# not regression. Fix : short-circuit on GivenFailed — no log entry,
# no Doctor.NoteConcern dispatch.
#
# Coordination : Phase 0e covers the dispatch-wrapper end-to-end (Doctor
# concern shape, log line format, AggregateNotFound/LifecycleViolation
# routing). This file covers the i207-specific contract — that GivenFailed
# is silent at the runtime level — so that even if 0e is delayed, i207
# has explicit guardrail.

require_relative "spec_helper"

RSpec.describe "Dispatch wrapper failure modes (i207)" do
  let(:bluebook) { File.join(MIETTE_DIR, "body/sleep/consciousness.bluebook") }

  context "GivenFailed surfaces as a clean dispatch error, not a runtime crash" do
    it "Consciousness.AdvanceRemToDeep with insufficient pulses returns GivenFailed" do
      h = setup_harness("i207_given_failed")
      h.copy_bluebook(bluebook)

      h.heki_seed("consciousness/consciousness.heki",
                  id: "consciousness", name: "consciousness",
                  state: "sleeping", sleep_stage: "rem",
                  sleep_cycle: 1, sleep_total: 8, phase_ticks: 5,
                  dream_pulses: 2, dream_pulses_needed: 5, is_lucid: "no")

      result = h.dispatch("Consciousness.AdvanceRemToDeep", name: "consciousness")
      expect(result.ok?).to be(false), "GivenFailed should not pass as ok"
      # The dispatch error must name the failed expression — that's
      # how the wrapper distinguishes it from AggregateNotFound /
      # LifecycleViolation, which need a Doctor concern.
      expect(result.error_message).to match(/GivenFailed|dream_pulses/)
    end

    it "the heki row is unchanged when GivenFailed short-circuits" do
      # The atomicity contract : a GivenFailed dispatch must not
      # write any partial state. The seeded row is the row after.
      h = setup_harness("i207_no_partial_write")
      h.copy_bluebook(bluebook)

      seed = {
        id: "consciousness", name: "consciousness", state: "sleeping",
        sleep_stage: "rem", sleep_cycle: 1, sleep_total: 8,
        phase_ticks: 5, dream_pulses: 2, dream_pulses_needed: 5,
        is_lucid: "no"
      }
      h.heki_seed("consciousness/consciousness.heki", **seed)
      before = h.heki_latest("consciousness/consciousness.heki")

      h.dispatch("Consciousness.AdvanceRemToDeep", name: "consciousness")
      after = h.heki_latest("consciousness/consciousness.heki")

      # Domain attributes from the seed must survive verbatim ; the
      # heki framework may stamp metadata (created_at, updated_at) but
      # the lifecycle attributes must not drift.
      %w[state sleep_stage dream_pulses sleep_cycle].each do |k|
        expect(after[k]).to eq(before[k]),
          "GivenFailed dispatch wrote partial state ; #{k} drifted from #{before[k].inspect} to #{after[k].inspect}"
      end
    end
  end

  context "shell-side wrapper contract — Doctor concerns are NOT raised on GivenFailed" do
    it "documents the wrapper's design intent (i207)" do
      # The wrapper logic is duplicated across body/{pulse_organs,
      # mindstream, rem_branch, nrem_branch, consolidate}.sh. Each
      # carries an inline `i207 + Doctor wiring : short-circuit on
      # GivenFailed (design-level)` comment. This assertion locks
      # the comment marker in at least one shell so the contract is
      # discoverable from grep.
      shells = %w[
        body/mindstream.sh
        body/pulse_organs.sh
        body/rem_branch.sh
        body/nrem_branch.sh
        body/consolidate.sh
      ].map { |p| File.join(MIETTE_DIR, p) }

      with_marker = shells.select do |path|
        File.exist?(path) && File.read(path).include?("i207")
      end

      expect(with_marker).not_to be_empty,
        "no shell carries the i207 wrapper marker — the contract " \
        "may have drifted away from the documented design"
    end
  end
end
