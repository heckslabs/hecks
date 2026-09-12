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

  # THE PROPERTY'S OWN DETECTION LOGIC, PINNED DIRECTLY AGAINST A
  # SYNTHETIC `history[:instances]` — no longer reachable through a real
  # `Replay.call` at all, now that `CommandRules::References#enforce_
  # tenant_boundary` (runtime/command_rules/references.rb) refuses this
  # exact write at dispatch time (see the "now refuses for real" example
  # below). A refused write is never stored, so `history[:instances]`
  # can no longer hold one this shape through real dispatch — but the
  # property itself stays a real, permanent regression guard (if
  # `enforce_tenant_boundary` is ever broken by a later refactor, a
  # stray cross-tenant record landing in storage again is exactly what
  # this would catch), so its own logic is still worth pinning directly.
  # Built by replaying a REAL same-region Transfer to get REAL, correctly-
  # typed `Value` objects for every OTHER field, then hand-patching only
  # `:ledger` — the one plain scalar reference field — to point at the
  # other region's ledger, simulating exactly what an unenforced write
  # used to persist.
  it "fires on a stored Transfer whose own ledger reference disagrees with its region" do
    steps = [
      { "verb" => "TenantLedger::Ledger.Open",
        "args" => { code: { value: "L-EAST" }, region: { value: "east" } } },
      { "verb" => "TenantLedger::Ledger.Open",
        "args" => { code: { value: "L-WEST" }, region: { value: "west" } } },
      { "verb" => "TenantLedger::Transfer.Request",
        "args" => { reference: { value: "T-1" }, region: { value: "east" }, ledger: "L-EAST",
                    amount_cents: { value: 500 } } }
    ]
    history = replay(steps)
    history[:instances]["TenantLedger::Transfer#T-1"][:ledger] = "L-WEST"

    result = Hecks::Fuzzing::Properties.commands_respect_tenant_scope(history)

    expect(result).to be_a(String)
    expect(result).to include("TenantLedger::Transfer#T-1").and include("region")
    expect(result).to include("L-WEST").and include("west").and include("cross-tenant write nothing refused")
  end

  # THE REAL FIX, PROVEN AT DISPATCH TIME — `CommandRules::References#
  # enforce_tenant_boundary`, mirroring `TenantScope.apply`'s query-side
  # mechanism (runtime/tenant_scope.rb) for a command's own settled
  # state. `Transfer.Request` declaring `region: "east"` independently
  # of a `ledger:` that actually opened under "west" now refuses outright
  # — nothing is stored, so the saga (`SettleAcrossRegions`) never even
  # starts (it `starts_on Transfer::TransferRequested`, which a refused
  # `Request` never emits).
  it "now refuses for real: a Transfer.Request naming a ledger from a different region" do
    steps = [
      { "verb" => "TenantLedger::Ledger.Open",
        "args" => { code: { value: "L-EAST" }, region: { value: "east" } } },
      { "verb" => "TenantLedger::Ledger.Open",
        "args" => { code: { value: "L-WEST" }, region: { value: "west" } } },
      { "verb" => "TenantLedger::Transfer.Request",
        "args" => { reference: { value: "T-1" }, region: { value: "east" }, ledger: "L-WEST",
                    amount_cents: { value: 500 } } }
    ]
    history = replay(steps)

    expect(history[:instances]).not_to have_key("TenantLedger::Transfer#T-1")
    refusal = history[:refusals].find { |r| r[:verb] == "TenantLedger::Transfer.Request" }
    expect(refusal).not_to be_nil
    expect(refusal[:kind]).to eq("Hecks::Runtime::Unauthorized")
    expect(refusal[:error].to_s).to include("Transfer").and include("region").and include("east")
                                                          .and include("ledger").and include("Ledger")
                                                          .and include("west").and include("cross-tenant reference")

    # THE PROPERTY ITSELF HAS NOTHING TO SAY — the same "a refusal is
    # correct behaviour, not a finding" rule the third example below
    # already states for a dangling reference, now true for this shape
    # too.
    expect(Hecks::Fuzzing::Properties.commands_respect_tenant_scope(history)).to be(true)
  end

  # THE SAME-TENANT CONTROL, DISPATCHED FOR REAL — a `Transfer.Request`
  # whose `region` genuinely agrees with the ledger it names must still
  # succeed. Without this, a fix that refused EVERY `reference_to`
  # regardless of tenant agreement would look identical to the real one.
  it "still succeeds for real: a Transfer.Request naming a ledger from its own region" do
    steps = [
      { "verb" => "TenantLedger::Ledger.Open",
        "args" => { code: { value: "L-EAST" }, region: { value: "east" } } },
      { "verb" => "TenantLedger::Transfer.Request",
        "args" => { reference: { value: "T-4" }, region: { value: "east" }, ledger: "L-EAST",
                    amount_cents: { value: 250 } } }
    ]
    history = replay(steps)

    expect(history[:instances]).to have_key("TenantLedger::Transfer#T-4")
    expect(history[:refusals].map { |r| r[:verb] }).not_to include("TenantLedger::Transfer.Request")
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
