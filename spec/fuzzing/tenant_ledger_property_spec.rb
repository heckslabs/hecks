require "spec_helper"
require "hecks/fuzzing"

# Pins `Hecks::Fuzzing::Properties.commands_respect_tenant_scope` against the tenant_ledger
# stress domain, in both directions: it fires on a cross-tenant write, never on a same-tenant one.
RSpec.describe "Hecks::Fuzzing::Properties.commands_respect_tenant_scope" do
  TENANT_LEDGER_STRESS_DOMAIN = File.join(InMemoryDomain::ROOT, "qa/stress_domains/tenant_ledger")

  def replay(steps)
    Hecks::Fuzzing::Replay.call(TENANT_LEDGER_STRESS_DOMAIN, steps)
  end

  # Dispatch now refuses this write, so the detection logic is pinned on a synthetic history.
  # Built by replaying a same-region Transfer for correctly-
  # typed `Value` objects for every other field, then hand-patching only
  # `:ledger` to the other region's ledger.
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

  # `CommandRules::References#enforce_tenant_boundary` refuses the write, so nothing is stored
  # and the saga never starts.
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
    message = refusal[:error].to_s
    ["Transfer", "region", "east", "ledger", "Ledger", "west", "cross-tenant reference"].each do |fragment|
      expect(message).to include(fragment)
    end

    # A refusal is correct behaviour, not a finding.
    expect(Hecks::Fuzzing::Properties.commands_respect_tenant_scope(history)).to be(true)
  end

  # Control: a same-region Request must still succeed, or a blanket `reference_to` refusal would
  # pass the test above.
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

  # Control: a same-region Request must pass, or a property that flagged every reference would
  # look identical to the real one.
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

  # A step that never wrote a record cannot appear in `history[:instances]`; the property claims
  # nothing either way.
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

  # Excludes `commands_respect_tenant_scope`: two random `region` strings almost never coincide,
  # so it fires on nearly every seed by design and is pinned by the hand-built examples above.
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

  # No false positives on domains with no second tenant-scoped aggregate to cross. The corpus is
  # derived (`Hecks::Corpus.rust_domains`) with a fixed 50-seed total spread across it.
  it "never fires on the existing corpus, which declares no second tenant-scoped aggregate to cross" do
    domains = Hecks::Corpus.rust_domains.map(&:dir).reject { |dir| dir == TENANT_LEDGER_STRESS_DOMAIN }
    domains.each do |domain|
      (1..(50.0 / domains.size).ceil).each do |seed|
        steps = Hecks::Fuzzing::SequenceGenerator.generate(domain, seed: seed, steps: 25)
        history = Hecks::Fuzzing::Replay.call(domain, steps)
        result = Hecks::Fuzzing::Properties.commands_respect_tenant_scope(history)

        expect(result).to be(true), "#{domain} seed #{seed}: #{result}"
      end
    end
  end
end
