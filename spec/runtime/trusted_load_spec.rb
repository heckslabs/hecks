require "spec_helper"

# C6.3 (docs/semantics/bluebook-semantics.md) — value-object validation
# runs on construction from INPUT only. State read back from the store is
# trusted as it was written, so tightening an invariant never makes an
# old record unreadable; migration is the era system's job.
RSpec.describe "trusted stored state (C6.3)" do
  let(:runtime) { Hecks.boot(File.join(InMemoryDomain::ROOT, "examples/banking")) }
  let(:account) { runtime.registry.bluebook("Banking").aggregate("Account") }

  it "refuses a value object built from input that breaks its invariant" do
    expect { Hecks::Runtime::Value.for(account, :balance, cents: 5, currency: "US") }
      .to raise_error(Hecks::Runtime::InvariantViolation)
  end

  it "loads the same shape from the store without re-judging it" do
    hydrated = Hecks::Runtime::Value.hydrate(account, balance: { cents: 5, currency: "US" })

    expect(hydrated[:balance].to_h).to eq(cents: 5, currency: "US")
  end

  it "leaves the input door strict once the load is over" do
    Hecks::Runtime::Value.hydrate(account, balance: { cents: 5, currency: "US" })

    expect { Hecks::Runtime::Value.for(account, :balance, cents: 5, currency: "US") }
      .to raise_error(Hecks::Runtime::InvariantViolation)
  end
end
