require "spec_helper"
require "hecks/fuzzing"

# `Properties.corrections_reference_an_emitted_event`. The entity-level examples hand-build
# `history`: the corrections stress domain raises WiringError when `Ledger.Entry.Amend` dispatches.
# The constant names are distinctive because spec/load_hygiene_spec.rb refuses shared ones.
RSpec.describe "Hecks::Fuzzing::Properties.corrections_reference_an_emitted_event" do
  CORRECTIONS_SPEC_ROOT   = InMemoryDomain::ROOT
  CORRECTIONS_SPEC_DOMAIN = File.join(CORRECTIONS_SPEC_ROOT, "qa/stress_domains/corrections")
  CORRECTIONS_SPEC_BANKING = File.join(CORRECTIONS_SPEC_ROOT, "examples/banking")

  def bluebooks_for(domain)
    Hecks::Fuzzing::Replay.call(domain, [])[:bluebooks]
  end

  # The corpus's one working `corrects` command, so the one path with a real replay.
  describe "the aggregate-level case (examples/banking, real dispatch)" do
    def unique_reference
      "CORR-#{rand(1_000_000_000)}"
    end

    def opened_account_steps(reference, number)
      [
        { "verb" => "Banking::Customer.Register",
          "args" => { "reference" => { "value" => reference },
                      "name"      => { "given" => "Ada", "family" => "Lovelace" },
                      "email"     => { "address" => "ada@example.com" } } },
        { "verb" => "Banking::Account.Open",
          "args" => { "number" => { "value" => number }, "kind" => { "name" => "current" },
                      "daily_limit" => { "cents" => 50_000 }, "customer" => reference } }
      ]
    end

    it "passes a correction genuinely preceded by the event it claims to correct" do
      reference = unique_reference
      number    = unique_reference
      steps = opened_account_steps(reference, number) + [
        { "verb" => "Banking::Account.Credit",
          "args" => { "number" => { "value" => number }, "amount" => { "cents" => 10_000, "currency" => "USD" },
                      "narrative" => { "text" => "Opening deposit" } } },
        { "verb" => "Banking::Account.ApplyFee",
          "args" => { "number" => { "value" => number }, "amount" => { "cents" => 100, "currency" => "USD" },
                      "narrative" => { "text" => "Monthly maintenance" } } },
        { "verb" => "Banking::Account.CorrectFee",
          "args" => { "number" => { "value" => number }, "amount" => { "cents" => 100, "currency" => "USD" } } }
      ]

      history = Hecks::Fuzzing::Replay.call(CORRECTIONS_SPEC_BANKING, steps)

      expect(history[:refusals]).to eq([])
      expect(Hecks::Fuzzing::Properties.corrections_reference_an_emitted_event(history)).to be(true)
    end

    it "names a correction whose claimed event never precedes it in the same history — the seeded-failure fixture" do
      reference = unique_reference
      number    = unique_reference
      steps = opened_account_steps(reference, number) + [
        { "verb" => "Banking::Account.Credit",
          "args" => { "number" => { "value" => number }, "amount" => { "cents" => 10_000, "currency" => "USD" },
                      "narrative" => { "text" => "Opening deposit" } } },
        { "verb" => "Banking::Account.ApplyFee",
          "args" => { "number" => { "value" => number }, "amount" => { "cents" => 100, "currency" => "USD" },
                      "narrative" => { "text" => "Monthly maintenance" } } },
        { "verb" => "Banking::Account.CorrectFee",
          "args" => { "number" => { "value" => number }, "amount" => { "cents" => 100, "currency" => "USD" } } }
      ]
      history = Hecks::Fuzzing::Replay.call(CORRECTIONS_SPEC_BANKING, steps)
      expect(history[:refusals]).to eq([])

      # Seeded, not dispatched: a real `CorrectFee` without `FeeApplied` refuses, so the event
      # is stripped from an otherwise-real history.
      doctored_events = history[:events].reject { |event| event[:name] == "FeeApplied" }
      doctored = history.merge(events: doctored_events)

      result = Hecks::Fuzzing::Properties.corrections_reference_an_emitted_event(doctored)
      expect(result).to be_a(String)
      expect(result).to include("CorrectFee")
      expect(result).to include("FeeApplied")
    end
  end

  # `Ledger.Entry.Amend` cannot be dispatched (see the header), so `history` is hand-built from
  # real objects of a zero-step boot plus a hand-written `events` array.
  describe "the entity-level case (qa/stress_domains/corrections, hand-built history)" do
    let(:bluebooks) { bluebooks_for(CORRECTIONS_SPEC_DOMAIN) }

    it "passes a hand-built history where EntryRecorded genuinely precedes EntryAmended for the same id" do
      history = { bluebooks: bluebooks,
                  events:    [
                    { name: "LedgerOpened",   aggregate: "Corrections::Ledger", id: "L-1", payload: {} },
                    { name: "EntryRecorded",  aggregate: "Corrections::Ledger", id: "L-1", payload: {} },
                    { name: "EntryAmended",   aggregate: "Corrections::Ledger", id: "L-1", payload: {} }
                  ] }

      expect(Hecks::Fuzzing::Properties.corrections_reference_an_emitted_event(history)).to be(true)
    end

    it "names an EntryAmended with no preceding EntryRecorded for the same ledger — " \
       "exactly what Rust's own generated code accepts unconditionally today (see NOTES.md)" do
      history = { bluebooks: bluebooks,
                  events:    [
                    { name: "LedgerOpened", aggregate: "Corrections::Ledger", id: "L-1", payload: {} },
                    { name: "EntryAmended", aggregate: "Corrections::Ledger", id: "L-1", payload: {} }
                  ] }

      result = Hecks::Fuzzing::Properties.corrections_reference_an_emitted_event(history)
      expect(result).to be_a(String)
      expect(result).to include("Amend")
      expect(result).to include("EntryAmended")
      expect(result).to include("EntryRecorded")
    end

    it "does not confuse two different ledgers — an EntryRecorded on a DIFFERENT id does not excuse the correction" do
      history = { bluebooks: bluebooks,
                  events:    [
                    { name: "LedgerOpened",  aggregate: "Corrections::Ledger", id: "L-1", payload: {} },
                    { name: "LedgerOpened",  aggregate: "Corrections::Ledger", id: "L-2", payload: {} },
                    { name: "EntryRecorded", aggregate: "Corrections::Ledger", id: "L-2", payload: {} },
                    { name: "EntryAmended",  aggregate: "Corrections::Ledger", id: "L-1", payload: {} }
                  ] }

      result = Hecks::Fuzzing::Properties.corrections_reference_an_emitted_event(history)
      expect(result).to be_a(String)
      expect(result).to include("L-1")
    end

    it "does not confuse order — an EntryRecorded AFTER the EntryAmended does not excuse it either" do
      history = { bluebooks: bluebooks,
                  events:    [
                    { name: "LedgerOpened",  aggregate: "Corrections::Ledger", id: "L-1", payload: {} },
                    { name: "EntryAmended",  aggregate: "Corrections::Ledger", id: "L-1", payload: {} },
                    { name: "EntryRecorded", aggregate: "Corrections::Ledger", id: "L-1", payload: {} }
                  ] }

      result = Hecks::Fuzzing::Properties.corrections_reference_an_emitted_event(history)
      expect(result).to be_a(String)
    end
  end
end
