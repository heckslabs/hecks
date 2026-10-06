require "spec_helper"
require "hecks/fuzzing"

# Pins `Hecks::Fuzzing::Properties.commands_respect_tenant_scope` against the tenant_ledger
# stress domain, in both directions: it fires on a cross-tenant write, never on a same-tenant one.
RSpec.describe "Hecks::Fuzzing::Properties.commands_respect_tenant_scope", :aggregate_failures do
  TENANT_LEDGER_STRESS_DOMAIN = File.join(InMemoryDomain::ROOT, "qa/stress_domains/tenant_ledger")

  def replay(steps)
    Hecks::Fuzzing::Replay.call(TENANT_LEDGER_STRESS_DOMAIN, steps)
  end

  def open_ledger(code, region)
    { "verb" => "TenantLedger::Ledger.Open", "args" => { code: { value: code }, region: { value: region } } }
  end

  def request_transfer(reference, region, ledger, cents)
    { "verb" => "TenantLedger::Transfer.Request",
      "args" => { reference: { value: reference }, region: { value: region }, ledger: ledger,
                  amount_cents: { value: cents } } }
  end

  def tenant_scope(history) = Hecks::Fuzzing::Properties.commands_respect_tenant_scope(history)

  def cross_tenant_fragments
    ["TenantLedger::Transfer#T-1", "region", "L-WEST", "west", "cross-tenant write nothing refused"]
  end

  # Dispatch now refuses this write, so the detection logic is pinned on a synthetic history.
  # Built by replaying a same-region Transfer for correctly-
  # typed `Value` objects for every other field, then hand-patching only
  # `:ledger` to the other region's ledger.
  it "fires on a stored Transfer whose own ledger reference disagrees with its region" do
    steps = [open_ledger("L-EAST", "east"), open_ledger("L-WEST", "west"), request_transfer("T-1", "east", "L-EAST", 500)]
    history = replay(steps)
    history[:instances]["TenantLedger::Transfer#T-1"][:ledger] = "L-WEST"
    result = tenant_scope(history)

    expect(result).to be_a(String).and include(*cross_tenant_fragments)
  end

  # `CommandRules::References#enforce_tenant_boundary` refuses the write, so nothing is stored
  # and the saga never starts.
  context "with a Transfer.Request naming a ledger from a different region" do
    before do
      steps = [open_ledger("L-EAST", "east"), open_ledger("L-WEST", "west"), request_transfer("T-1", "east", "L-WEST", 500)]
      @history = replay(steps)
    end

    it "now refuses for real, naming the cross-tenant reference" do
      refusal = @history[:refusals].find { |r| r[:verb] == "TenantLedger::Transfer.Request" }

      expect(refusal&.fetch(:kind)).to eq("Hecks::Runtime::Unauthorized")
      expect(refusal&.fetch(:error).to_s).to include("Transfer", "region", "east", "ledger", "Ledger", "west",
                                                     "cross-tenant reference")
    end

    it "stores nothing, and a refusal is correct behaviour, not a finding" do
      expect(@history[:instances]).not_to have_key("TenantLedger::Transfer#T-1")
      expect(tenant_scope(@history)).to be(true)
    end
  end

  # Control: a same-region Request must still succeed, or a blanket `reference_to` refusal would
  # pass the test above.
  it "still succeeds for real: a Transfer.Request naming a ledger from its own region" do
    history = replay([open_ledger("L-EAST", "east"), request_transfer("T-4", "east", "L-EAST", 250)])

    expect(history[:instances]).to have_key("TenantLedger::Transfer#T-4")
    expect(history[:refusals].map { |r| r[:verb] }).not_to include("TenantLedger::Transfer.Request")
  end

  # Control: a same-region Request must pass, or a property that flagged every reference would
  # look identical to the real one.
  it "passes a Transfer.Request naming a ledger from its own region" do
    steps = [open_ledger("L-EAST", "east"), request_transfer("T-2", "east", "L-EAST", 100)]

    expect(tenant_scope(replay(steps))).to be(true)
  end

  # A step that never wrote a record cannot appear in `history[:instances]`; the property claims
  # nothing either way.
  it "has nothing to say about a Request that never resolves (no such ledger, so nothing is stored)" do
    history = replay([request_transfer("T-3", "east", "NOPE", 100)])

    expect(history[:instances]).to be_empty
    expect(tenant_scope(history)).to be(true)
  end

  def battery_results(seed)
    steps = Hecks::Fuzzing::SequenceGenerator.generate(TENANT_LEDGER_STRESS_DOMAIN, seed: seed, steps: 25)
    Hecks::Fuzzing::Properties.check(replay(steps)).except(:commands_respect_tenant_scope)
  end

  # Excludes `commands_respect_tenant_scope`: two random `region` strings almost never coincide,
  # so it fires on nearly every seed by design and is pinned by the hand-built examples above.
  it "holds the standard battery (tenant_scope aside) for 15 generated seeds" do
    (1..15).each do |seed|
      battery_results(seed).each do |property, result|
        expect(result).to be(true), "tenant_ledger seed #{seed} — #{property}: #{result}"
      end
    end
  end

  def corpus_domains
    Hecks::Corpus.rust_domains.map(&:dir).reject { |dir| dir == TENANT_LEDGER_STRESS_DOMAIN }
  end

  # Every `domain seed N: result` line for a corpus run whose property answer was not true.
  def corpus_failures(domains)
    seeds = (1..(50.0 / domains.size).ceil).to_a
    domains.product(seeds).filter_map do |domain, seed|
      steps = Hecks::Fuzzing::SequenceGenerator.generate(domain, seed: seed, steps: 25)
      result = tenant_scope(Hecks::Fuzzing::Replay.call(domain, steps))
      "#{domain} seed #{seed}: #{result}" unless result == true
    end
  end

  # No false positives on domains with no second tenant-scoped aggregate to cross. The corpus is
  # derived (`Hecks::Corpus.rust_domains`) with a fixed 50-seed total spread across it.
  it "never fires on the existing corpus, which declares no second tenant-scoped aggregate to cross" do
    expect(corpus_failures(corpus_domains)).to be_empty
  end
end
