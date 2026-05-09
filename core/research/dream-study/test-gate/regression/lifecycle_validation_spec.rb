# lifecycle_validation_spec.rb
#
# [antibody-exempt: dream-study Phase 0f regression — covers named
#  bug i201 ; static bluebook-source assertion until lifecycle
#  validator surfaces "rested" mismatch on its own]
#
# Regression coverage for i201 — heartbeat.fatigue_state lifecycle
# violation. Production heki rows carry fatigue_state="rested" but
# the heartbeat.bluebook lifecycle declares no transition into
# "rested". The value is being written outside the declared
# lifecycle (probably by direct heki upsert during wake recovery).
#
# This spec parses heartbeat.bluebook and asserts which lifecycle
# values it actually declares — capturing today's drift so the
# follow-up fix (either declare "rested" or normalise back to
# "alert") has a guard rail.

require_relative "spec_helper"

RSpec.describe "Heartbeat lifecycle declaration (i201)" do
  let(:bluebook_path) { File.join(MIETTE_DIR, "body/cycles/heartbeat.bluebook") }
  let(:source)        { File.read(bluebook_path) }

  it "declares the canonical fatigue ladder rungs in the lifecycle block" do
    # The lifecycle block lists every transition. Each rung's
    # destination state must appear. This is the current contract —
    # passes today, will continue to pass after the i201 fix lands
    # (because the fix adds "rested" as a NEW transition, doesn't
    # remove existing ones).
    %w[focused normal tired exhausted delirious alert].each do |rung|
      expect(source).to match(/=>\s*"#{rung}"/),
        "heartbeat.bluebook lifecycle is missing the #{rung} rung"
    end
  end

  it "tracks i201 — 'rested' is NOT yet a declared lifecycle value" do
    # i201 surfaced when production heki carried fatigue_state="rested"
    # but the lifecycle had no transition into it. Today's bluebook is
    # frozen on this gap ; the test locks the gap so when the fix
    # lands (adding `transition "RecoverFatigue" => "rested", ...`),
    # the test fails clearly and the fixer updates this expectation.
    pending "i201 — bluebook does not declare 'rested' as a fatigue " \
            "state ; production heki rows carry it anyway. Fix : " \
            "either add the transition (proper) or normalise " \
            "RecoverFatigue's then_set back to 'alert' (current " \
            "behaviour). Track this assertion until decided."
    expect(source).to match(/=>\s*"rested"/),
      "lifecycle should declare 'rested' once i201 is resolved"
  end

  it "RecoverFatigue's then_set sets fatigue_state to 'alert' (current contract)" do
    # The bluebook today resets fatigue_state to "alert" inside
    # RecoverFatigue. The mismatch between this bluebook intent and
    # the actual heki ("rested") is exactly i201. Lock the bluebook
    # intent here so any future drift in the source is visible.
    expect(source).to include('then_set :fatigue_state, to: "alert"')
  end

  it "lifecycle covers RecoverFatigue from every reachable state" do
    # The transition list for RecoverFatigue must include every
    # fatigue_state the body can be in at wake time, otherwise wake
    # silently fails to reset fatigue_state (the original i201
    # symptom).
    expect(source).to match(
      /transition\s+"RecoverFatigue"\s*=>\s*"alert",\s*from:\s*\[
        ("alert"|"focused"|"normal"|"tired"|"exhausted"|"delirious"|,|\s)+
       \]/x
    )
  end
end
