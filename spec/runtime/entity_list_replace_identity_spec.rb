require "spec_helper"
require "hecks/fuzzing"

# BUG#33 (QualityControl ledger) — the duplicate-identity guard BUG#13
# added for a single caller-supplied `append:` (`MutationApplier#
# check_entity_collision`, mutation_applier.rb) never extended to a
# whole-list `:set` REPLACE (`sets :entries` bare — `Ledger.
# ReplaceEntries`, `qa/stress_domains/corrections`, the corpus's first
# `list_of(ENTITY)` command argument/mutation). `Value::Coercion#
# hydrate_entity_list` rebuilt each offered element's own declared
# fields but never checked the offered list itself for a caller naming
# the same identity twice, or naming none at all.
#
# Uses `Hecks::Fuzzing::Replay.call`, the same real-dispatch pattern
# `spec/fuzzing/properties/corrections_spec.rb` already uses for this
# domain — a genuine end-to-end dispatch through the ordinary command
# interpreter, not a hand-built fixture.
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

    # THE DUPLICATE NEVER LANDED — the whole mutation refuses, exactly
    # as `check_entity_collision`'s own append-time guard behaves (a
    # refused dispatch writes nothing).
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

# THE DIFFERENTIAL COUNTERPART — `bin/rust_conformance qa/stress_domains/
# corrections <script> native`, run by hand against the freshly rebuilt
# `corrections`-feature binary during this fix's own verification: both
# the duplicate-identity refusal (verb, kind, AND wording, once
# `entity_list_replace_guard`'s own "offered" rendering was made to
# unwrap a single-field identity the same way `Rendering.describe` does)
# and the successful distinct-identity replace agree byte for byte
# between the two engines. The missing-identity case agrees on verb and
# kind (both TypeMismatch) but not on wording — Rust's generated `Entry::
# from_json` already refuses a structurally-absent field via its own
# pre-existing, generic `Json#require` helper ("Entry.sequence: missing
# from JSON args"), a wording convention shared by every generated
# entity's `from_json` corpus-wide, not something this fix introduced or
# narrows further — unifying it with Ruby's own generic "{type}.{field}
# expects {expected}, got {offered}" template would mean rewriting that
# shared Rust primitive for every domain, well outside this fix's own
# scope (see this file's own examples above, `check_entity_list_
# identities`'s own comment in coercion.rb, and `entity_list_replace_
# guard`'s own comment, rust/project/mutations.rb).
