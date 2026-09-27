require "spec_helper"
require "hecks/fuzzing"

# A whole-list `sets :entries` replace must refuse an offered list that repeats an identity or
# names none, as the append-time guard does; runs Ledger.ReplaceEntries through `Fuzzing::Replay`.
RSpec.describe "Ledger.ReplaceEntries — a whole-list entity replace" do
  ENTITY_LIST_REPLACE_IDENTITY_DOMAIN = File.join(InMemoryDomain::ROOT, "qa/stress_domains/corrections")

  def open_ledger_step(reference)
    { "verb" => "Corrections::Ledger.Open", "args" => { "reference" => { "value" => reference } } }
  end

  def replace_entries_step(reference, entries)
    { "verb" => "Corrections::Ledger.ReplaceEntries", "args" => { "reference" => { "value" => reference }, "entries" => entries } }
  end

  it "refuses a replacement list carrying a duplicate identity, the same way append already does" do
    steps = [
      open_ledger_step("L-DUP"),
      replace_entries_step("L-DUP", [
                             { "sequence" => { "value" => 1 }, "amount" => { "cents" => 100 } },
                             { "sequence" => { "value" => 1 }, "amount" => { "cents" => 200 } }
                           ])
    ]

    history = Hecks::Fuzzing::Replay.call(ENTITY_LIST_REPLACE_IDENTITY_DOMAIN, steps)

    expect(history[:refusals].size).to eq(1)
    refusal = history[:refusals].first
    expect(refusal[:verb]).to eq("Corrections::Ledger.ReplaceEntries")
    expect(refusal[:kind]).to eq("Hecks::Runtime::AlreadyExists")
    expect(refusal[:error]).to eq("a Entry already exists on Ledger — sequence.value 1")

    # The whole mutation refuses, so the duplicate never lands.
    instance = history[:instances].values.find { |record| record[:reference].to_h == { value: "L-DUP" } }
    expect(instance[:entries]).to eq([])
  end

  it "refuses a replacement list carrying an element with no identity at all" do
    steps = [
      open_ledger_step("L-MISSING"),
      replace_entries_step("L-MISSING", [
                             { "amount" => { "cents" => 300 } }
                           ])
    ]

    history = Hecks::Fuzzing::Replay.call(ENTITY_LIST_REPLACE_IDENTITY_DOMAIN, steps)

    expect(history[:refusals].size).to eq(1)
    refusal = history[:refusals].first
    expect(refusal[:verb]).to eq("Corrections::Ledger.ReplaceEntries")
    expect(refusal[:kind]).to eq("Hecks::Runtime::TypeMismatch")
    expect(refusal[:error]).to eq("Entry.sequence expects EntrySequence, got nil")
  end

  it "accepts a replacement list whose elements each carry their own distinct identity" do
    steps = [
      open_ledger_step("L-OK"),
      replace_entries_step("L-OK", [
                             { "sequence" => { "value" => 1 }, "amount" => { "cents" => 100 } },
                             { "sequence" => { "value" => 2 }, "amount" => { "cents" => 200 } }
                           ])
    ]

    history = Hecks::Fuzzing::Replay.call(ENTITY_LIST_REPLACE_IDENTITY_DOMAIN, steps)

    expect(history[:refusals]).to eq([])
    instance = history[:instances].values.find { |record| record[:reference].to_h == { value: "L-OK" } }
    expect(instance[:entries].map { |entry| entry[:sequence].to_h }).to eq([{ value: 1 }, { value: 2 }])
  end
end

# The Rust engine agrees on verb and kind for a missing identity but not on wording, because
# generated `Entry::from_json` refuses an absent field with its own generic message.
