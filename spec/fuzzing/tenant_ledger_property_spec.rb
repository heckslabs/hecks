require "spec_helper"
require "hecks/fuzzing"

# Pins `Hecks::Fuzzing::Properties.commands_respect_tenant_scope`
# (lib/hecks/fuzzing/properties/guards.rb, beside `authorize_scopes_or_
# refuses`) against `qa/stress_domains/tenant_ledger`, ANGLE-8's own
# stress domain — same two-direction discipline `spec/fuzzing/
# properties_spec.rb`'s own "each property, seen failing" section
# already holds every OTHER property to: a property nothing can ever
# fail is decoration, and a property that fires on a same-tenant write
# is a false-positive generator, not a real check.
RSpec.describe "Hecks::Fuzzing::Properties.commands_respect_tenant_scope" do
  TENANT_LEDGER_STRESS_DOMAIN = File.join(InMemoryDomain::ROOT, "qa/stress_domains/tenant_ledger")

  def replay(steps)
    Hecks::Fuzzing::Replay.call(TENANT_LEDGER_STRESS_DOMAIN, steps)
  end

  # THE SEEDED BUG — a fixture command sequence that ACCEPTS a
  # cross-tenant reference: `Transfer.Request` declares its own `region`
  # ("east") independently of `ledger`, which names a Ledger actually
  # opened under "west". Nothing in the runtime refuses this (`Tenant
  # Scope` never runs for a command — this domain's own NOTES.md/
  # bluebook header have the full argument), so the write lands and the
  # saga (`SettleAcrossRegions`) goes on to credit the west ledger
  # anyway — the property is what's supposed to catch what dispatch
  # itself does not.
  it "fires on a Transfer.Request naming a ledger from a different region" do
    steps = [
      { "verb" => "TenantLedger::Ledger.Open",
        "args" => { code: { value: "L-EAST" }, region: { value: "east" } } },
      { "verb" => "TenantLedger::Ledger.Open",
        "args" => { code: { value: "L-WEST" }, region: { value: "west" } } },
      { "verb" => "TenantLedger::Transfer.Request",
        "args" => { reference: { value: "T-1" }, region: { value: "east" }, ledger: "L-WEST",
                    amount_cents: { value: 500 } } }
    ]

    result = Hecks::Fuzzing::Properties.commands_respect_tenant_scope(replay(steps))

    expect(result).to be_a(String)
    expect(result).to include("TenantLedger::Transfer#T-1").and include("region")
    expect(result).to include("L-WEST").and include("west").and include("cross-tenant write nothing refused")
  end

  # THE CONTROL — the identical shape, same-region, must pass. Without
  # this, a property that flagged EVERY reference regardless of tenant
  # agreement would look identical to the real thing above.
  it "passes a Transfer.Request naming a ledger from its own region" do
    steps = [
      { "verb" => "TenantLedger::Ledger.Open",
        "args" => { code: { value: "L-EAST" }, region: { value: "east" } } },
      { "verb" => "TenantLedger::Transfer.Request",
        "args" => { reference: { value: "T-2" }, region: { value: "east" }, ledger: "L-EAST",
                    amount_cents: { value: 100 } } }
    ]

    expect(Hecks::Fuzzing::Properties.commands_respect_tenant_scope(replay(steps))).to be(true)
  end

  # A REFUSED CROSS-TENANT ATTEMPT IS NOT A FINDING — this domain's own
  # aggregates admit a malformed/incomplete Request the same as any other
  # (AbsentArgument, a nonexistent ledger, …), and a step that never wrote
  # a record can never appear in `history[:instances]` for this property
  # to have an opinion about — the property claims nothing about it
  # either way, the same "a refusal is correct behaviour, not a finding"
  # rule ANGLE-8 itself states.
  it "has nothing to say about a Request that never resolves (no such ledger, so nothing is stored)" do
    steps = [
      { "verb" => "TenantLedger::Transfer.Request",
        "args" => { reference: { value: "T-3" }, region: { value: "east" }, ledger: "NOPE",
                    amount_cents: { value: 100 } } }
    ]

    history = replay(steps)
    expect(history[:instances]).to be_empty
    expect(Hecks::Fuzzing::Properties.commands_respect_tenant_scope(history)).to be(true)
  end

  # THE STANDARD BATTERY, over real generated sequences — the same
  # discipline `spec/fuzzing/properties_spec.rb` runs for every other
  # domain it names, pinning that EVERY OTHER declared property holds for
  # this domain across many seeds — proof the domain's only real defect
  # is the one gap it was built to expose, not an authoring mistake
  # elsewhere. `commands_respect_tenant_scope` itself is EXCLUDED here on
  # purpose: two independently random `region` strings almost never
  # coincide, so it fires on nearly every generated seed by design — that
  # is the finding, not a regression, and is pinned directly by the two
  # hand-built examples above instead.
  it "holds the standard battery (tenant_scope aside) for 15 generated seeds" do
    (1..15).each do |seed|
      steps = Hecks::Fuzzing::SequenceGenerator.generate(TENANT_LEDGER_STRESS_DOMAIN, seed: seed, steps: 25)
      history = replay(steps)
      results = Hecks::Fuzzing::Properties.check(history).except(:commands_respect_tenant_scope)

      results.each do |property, result|
        expect(result).to be(true), "tenant_ledger seed #{seed} — #{property}: #{result}"
      end
    end
  end

  # NO FALSE POSITIVES ON DOMAINS WITH NO SECOND TENANT-SCOPED AGGREGATE
  # TO CROSS — `SafeDepositBox.Rented` (the only OTHER `authorize`/
  # `tenant:` site in the corpus) has no `reference_to` pointing at
  # another tenant-scoped aggregate at all, so this property should never
  # fire on banking, or on any domain declaring no `authorize`/`tenant:`
  # in the first place.
  it "never fires on the existing corpus, which declares no second tenant-scoped aggregate to cross" do
    %w[examples/pizzas examples/banking qa/stress_domains/nested_pieces qa/stress_domains/waybill
       qa/stress_domains/ledger_ordering].map { |rel| File.join(InMemoryDomain::ROOT, rel) }.each do |domain|
      (1..10).each do |seed|
        steps = Hecks::Fuzzing::SequenceGenerator.generate(domain, seed: seed, steps: 25)
        history = Hecks::Fuzzing::Replay.call(domain, steps)
        result = Hecks::Fuzzing::Properties.commands_respect_tenant_scope(history)

        expect(result).to be(true), "#{domain} seed #{seed}: #{result}"
      end
    end
  end
end
