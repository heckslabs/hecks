# signal_math_spec.rb — Phase 0g invariants 5-7
#
# Locks the numeric math + archive eligibility rule for the Signal
# aggregate (i106 + i204 dispatch-by-id). The audit found
# body/organs/signal.behaviors asserts only command shape, not the
# initial access_count=0 contract or the archive-eligibility rule
# (`access_count <= 3 AND age > 20s`) that pulse_organs.sh enforces.
#
# Invariants asserted :
#   5. FireSignal — access_count starts at 0
#      a. dispatch FireSignal ; expect access_count=0
#   6. AccessSignal — access_count += 1
#      a. seed access_count=0 ; dispatch AccessSignal ; expect 1
#   7. Archive eligibility rule (pulse_organs.sh shell logic)
#      A signal qualifies for ArchiveSignal iff
#      access_count <= 3 AND (now - created_at) > 20 seconds AND
#      kind != "archived"
#      a. eligible : access_count=3, age=21s → eligible (1 row in plan)
#      b. NOT eligible (recent) : access_count=0, age=5s → 0 rows
#      c. NOT eligible (hot) : access_count=4, age=300s → 0 rows
#      d. NOT eligible (already archived) : kind=archived → 0 rows
#
# Note : invariant 7 is enforced today by jq logic in pulse_organs.sh,
# not the bluebook itself. We test the rule by replicating the same
# selector against seeded heki rows. When the rule moves into the
# bluebook (Mind PM, Phase 4+), the test asserts the same contract on
# the new surface.

require_relative "spec_helper"
require "time"

RSpec.describe "Signal math + archive invariants" do
  before(:all) do
    skip DispatchHelper.skip_reason unless DispatchHelper.ready?
  end

  let(:helper) { DispatchHelper.new }

  describe "invariant 5 : FireSignal initializes access_count to 0" do
    it "(5) dispatch FireSignal ; access_count is 0" do
      helper.with_isolated_info do
        state = helper.dispatch("Signal.FireSignal",
                                kind: "somatic", payload: "pulse",
                                strength: 0.5,
                                created_at: "2026-05-01T00:00:00Z")
        expect(state.fetch("access_count").to_i).to eq(0)
      end
    end
  end

  describe "invariant 6 : AccessSignal increments access_count" do
    it "(6) seed access_count=0 ; dispatch AccessSignal ; expect 1" do
      helper.with_isolated_info do
        id = helper.seed("signal/signal.heki",
                         kind: "somatic", payload: "pulse",
                         strength: 0.5, access_count: 0,
                         created_at: "2026-05-01T00:00:00Z")
        state = helper.dispatch("Signal.AccessSignal", signal: id)
        expect(state.fetch("access_count").to_i).to eq(1)
      end
    end

    it "(6 follow-up) increments idempotently across dispatches" do
      helper.with_isolated_info do
        id = helper.seed("signal/signal.heki",
                         kind: "somatic", payload: "pulse",
                         strength: 0.5, access_count: 0,
                         created_at: "2026-05-01T00:00:00Z")
        helper.dispatch("Signal.AccessSignal", signal: id)
        helper.dispatch("Signal.AccessSignal", signal: id)
        state = helper.dispatch("Signal.AccessSignal", signal: id)
        expect(state.fetch("access_count").to_i).to eq(3)
      end
    end
  end

  describe "invariant 7 : archive eligibility rule" do
    # The rule lives in pulse_organs.sh:202-213 (jq selector). We
    # replicate it here against seeded rows + run ArchiveSignal only
    # against rows the selector picks. Future-proof : when the rule
    # moves into a bluebook, replace this Ruby selector with a single
    # `helper.dispatch("Signal.ArchiveColdSignals")`.
    def archive_eligible?(row, now_iso)
      return false if row["kind"] == "archived"
      return false unless (row["access_count"] || 0).to_i <= 3
      return false if row["created_at"].to_s.empty?
      age = Time.parse(now_iso) - Time.parse(row["created_at"])
      age > 20
    end

    it "(7a) eligible — access_count=3 + age=21s → archived" do
      now = "2026-05-01T00:00:21Z"
      helper.with_isolated_info do
        id = helper.seed("signal/signal.heki",
                         kind: "somatic", payload: "pulse",
                         strength: 0.5, access_count: 3,
                         created_at: "2026-05-01T00:00:00Z")
        rows = helper.list("signal/signal.heki")
        eligible = rows.select { |r| archive_eligible?(r, now) }
        expect(eligible.size).to eq(1)
        state = helper.dispatch("Signal.ArchiveSignal", signal: id)
        expect(state.fetch("kind")).to eq("archived")
      end
    end

    it "(7b) NOT eligible — access_count=0 but age=5s (too young)" do
      now = "2026-05-01T00:00:05Z"
      helper.with_isolated_info do
        helper.seed("signal/signal.heki",
                    kind: "somatic", payload: "pulse",
                    strength: 0.5, access_count: 0,
                    created_at: "2026-05-01T00:00:00Z")
        rows = helper.list("signal/signal.heki")
        eligible = rows.select { |r| archive_eligible?(r, now) }
        expect(eligible).to be_empty
      end
    end

    it "(7c) NOT eligible — age=300s but access_count=4 (hot, not cold)" do
      now = "2026-05-01T00:05:00Z"
      helper.with_isolated_info do
        helper.seed("signal/signal.heki",
                    kind: "concept", payload: "thought",
                    strength: 0.5, access_count: 4,
                    created_at: "2026-05-01T00:00:00Z")
        rows = helper.list("signal/signal.heki")
        eligible = rows.select { |r| archive_eligible?(r, now) }
        expect(eligible).to be_empty
      end
    end

    it "(7d) NOT eligible — kind=archived already" do
      now = "2026-05-01T00:05:00Z"
      helper.with_isolated_info do
        helper.seed("signal/signal.heki",
                    kind: "archived", payload: "old",
                    strength: 0.1, access_count: 1,
                    created_at: "2026-05-01T00:00:00Z")
        rows = helper.list("signal/signal.heki")
        eligible = rows.select { |r| archive_eligible?(r, now) }
        expect(eligible).to be_empty
      end
    end
  end
end
