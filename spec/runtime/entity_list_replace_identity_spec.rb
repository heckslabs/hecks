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

  def entry(sequence, cents) = { "sequence" => { "value" => sequence }, "amount" => { "cents" => cents } }

  # Replays an open then a whole-list replace of the ledger's entries.
  def replay_replace(reference, entries)
    steps = [open_ledger_step(reference), replace_entries_step(reference, entries)]
    Hecks::Fuzzing::Replay.call(ENTITY_LIST_REPLACE_IDENTITY_DOMAIN, steps)
  end

  def ledger_instance(history, reference)
    history[:instances].values.find { |record| record[:reference].to_h == { value: reference } }
  end

  it "refuses a replacement list carrying a duplicate identity, the same way append already does", :aggregate_failures do
    refusal = replay_replace("L-DUP", [entry(1, 100), entry(1, 200)])[:refusals].first

    expect(refusal[:verb]).to eq("Corrections::Ledger.ReplaceEntries")
    expect(refusal[:kind]).to eq("Hecks::Runtime::AlreadyExists")
    expect(refusal[:error]).to eq("a Entry already exists on Ledger — sequence.value 1")
  end

  it "refuses a replacement list carrying a duplicate identity as a whole, so the duplicate never lands",
     :aggregate_failures do
    history = replay_replace("L-DUP", [entry(1, 100), entry(1, 200)])

    expect(history[:refusals].size).to eq(1)
    # The whole mutation refuses, so the duplicate never lands.
    expect(ledger_instance(history, "L-DUP")[:entries]).to eq([])
  end

  it "refuses a replacement list carrying an element with no identity at all", :aggregate_failures do
    refusals = replay_replace("L-MISSING", [{ "amount" => { "cents" => 300 } }])[:refusals]

    expect(refusals.size).to eq(1)
    expect(refusals.first).to include(verb: "Corrections::Ledger.ReplaceEntries", kind: "Hecks::Runtime::TypeMismatch",
                                      error: "Entry.sequence expects EntrySequence, got nil")
  end

  it "accepts a replacement list whose elements each carry their own distinct identity", :aggregate_failures do
    history = replay_replace("L-OK", [entry(1, 100), entry(2, 200)])

    expect(history[:refusals]).to eq([])
    expect(ledger_instance(history, "L-OK")[:entries].map { |e| e[:sequence].to_h }).to eq([{ value: 1 }, { value: 2 }])
  end
end

# The Rust engine agrees on verb and kind for a missing identity but not on wording, because
# generated `Entry::from_json` refuses an absent field with its own generic message.
