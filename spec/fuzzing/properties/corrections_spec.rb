require "spec_helper"
require "hecks/fuzzing"

# `Hecks::Fuzzing::Properties.corrections_reference_an_emitted_event` —
# ANGLE-9 (QualityControl ledger `ask backlog`): `corrects` had exactly one
# declaration anywhere in the corpus (`examples/banking/bluebook/
# deposit_accounts.bluebook:353`, aggregate-level) and no property in
# `lib/hecks/fuzzing/properties.rb` ever checked it. This property's real
# target — an ENTITY-level `corrects` — cannot be reached through a real
# dispatch at all today: `qa/stress_domains/corrections` (this property's
# own stress domain, see its NOTES.md) crashes Ruby with
# `Hecks::Runtime::WiringError` the moment `Ledger.Entry.Amend` is actually
# dispatched, so every example below builds `history` BY HAND — the same
# "Replay.call(domain, [])" zero-step boot `spec/fuzzing/properties_spec.rb`'s
# own "each property, seen failing" section already uses to get real
# Aggregate/Command/Entity objects with no dispatch risk at all — rather
# than replaying real steps.
#
# `CORRECTIONS_SPEC_ROOT`/`CORRECTIONS_SPEC_DOMAIN` — distinctive constant
# names on purpose: spec/load_hygiene_spec.rb refuses two spec files
# sharing one top-level constant, and `properties_spec.rb` already owns
# `PROPERTIES_*`.
RSpec.describe "Hecks::Fuzzing::Properties.corrections_reference_an_emitted_event" do
  CORRECTIONS_SPEC_ROOT   = InMemoryDomain::ROOT
  CORRECTIONS_SPEC_DOMAIN = File.join(CORRECTIONS_SPEC_ROOT, "qa/stress_domains/corrections")
  CORRECTIONS_SPEC_BANKING = File.join(CORRECTIONS_SPEC_ROOT, "examples/banking")

  def bluebooks_for(domain)
    Hecks::Fuzzing::Replay.call(domain, [])[:bluebooks]
  end

  # THE AGGREGATE-LEVEL CASE, REAL DISPATCH — `examples/banking`'s own
  # `Account.CorrectFee` is the corpus's one working `corrects` command,
  # so this is the one path in this whole spec that can exercise the
  # property against a GENUINE replay rather than a hand-built history.
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

      # SEEDED, NOT DISPATCHED — a genuine `CorrectFee` with no preceding
      # `FeeApplied` refuses (NothingToCorrect) rather than ever landing in
      # `history[:events]`, so the only way to see this property actually
      # FIRE is to strip the preceding event out of an otherwise-real
      # history by hand, the same "seen failing" technique
      # `properties_spec.rb` already uses for every other property here.
      doctored_events = history[:events].reject { |event| event[:name] == "FeeApplied" }
      doctored = history.merge(events: doctored_events)

      result = Hecks::Fuzzing::Properties.corrections_reference_an_emitted_event(doctored)
      expect(result).to be_a(String)
      expect(result).to include("CorrectFee")
      expect(result).to include("FeeApplied")
    end
  end

  # THE ENTITY-LEVEL CASE THIS PROPERTY EXISTS TO WATCH. `Ledger.Entry.
  # Amend` cannot be reached through a real dispatch — see this file's own
  # header comment — so `history` is entirely hand-built here: real
  # `Aggregate`/`Entity`/`Command` objects (from a zero-step boot, no
  # dispatch at all) paired with a hand-written `events` array standing in
  # for what a WORKING implementation would have produced.
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
