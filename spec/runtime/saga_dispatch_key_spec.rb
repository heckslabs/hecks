require "spec_helper"
require "hecks/fuzzing"

# A saga dispatch's key names the one event that moved the leg (`DispatchClaim.key`). Two events
# on one aggregate share `id` and, within a second, `occurred_at`; the outbox's per-event uid is
# what tells them apart, so a second saga instance born for the same correlation delivers its own
# dispatches instead of losing the first instance's claim and applying nothing.
RSpec.describe "a saga dispatch key names one event" do
  SAGA_KEY_SPEC_DOMAIN = File.join(InMemoryDomain::ROOT, "qa/stress_domains/corrections")

  describe Hecks::Runtime::DispatchClaim do
    let(:event) do
      Hecks::Runtime::Event.new(name: "EntryAmended", aggregate: "Ledger", id: "L3", payload: {},
                                occurred_at: "2026-10-31T06:12:14Z")
    end

    def key_for(uid)
      described_class.key(process_manager: "CorrectionWatch", correlation: "L3", trigger: "EntryAmended",
                          event: event, index: 0, event_uid: uid)
    end

    it "tells two events apart that share name, aggregate identity and second" do
      expect(key_for("uid-1")).not_to eq(key_for("uid-2"))
    end

    it "recomputes the same key for the same event, as a redrive must" do
      expect(key_for("uid-1")).to eq(key_for("uid-1"))
    end
  end

  describe "two corrections to one ledger in one run (qa/stress_domains/corrections)" do
    def amend = { "verb" => "Corrections::Ledger.Entry.Amend",
                  "args" => { "reference" => { "value" => "L3" }, "sequence" => { "value" => 1 },
                              "amount" => { "cents" => 1 } } }

    def steps
      [{ "verb" => "Corrections::Ledger.Open", "args" => { "reference" => { "value" => "L3" } } },
       { "verb" => "Corrections::Ledger.Record", "args" => { "reference" => { "value" => "L3" }, "amount" => { "cents" => 1 } } },
       amend, amend]
    end

    let(:history) { Hecks::Fuzzing::Replay.call(SAGA_KEY_SPEC_DOMAIN, steps) }
    let(:open_dispatches) { history[:sagas].select { |row| row[:dispatch] == "AuditTrail.Open" } }

    it "refuses the second instance's Open because the audit trail already exists", :aggregate_failures do
      expect(open_dispatches.size).to eq(2)
      expect(open_dispatches.first).to include(delivered: true)
      expect(open_dispatches.last).to include(delivered: false)
      expect(open_dispatches.last[:reason]).to eq('Open creates a AuditTrail that already exists — reference.value "L3"')
    end

    it "opens the audit trail once and leaves it flagged", :aggregate_failures do
      expect(history[:events].map { |event| event[:name] }.count("AuditTrailOpened")).to eq(1)
      expect(history[:instances]["Corrections::AuditTrail#L3"][:status]).to eq("flagged")
    end
  end
end
