
require "spec_helper"

RSpec.describe "the rules a command obeys" do
  RULES_BANKING = File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook")
  RULES_TILL    = File.join(InMemoryDomain::ROOT, "spec/fixtures/till.bluebook")

  def boot(bluebook)
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(bluebook)
      Hecksagain::Runtime::Loader.bind_runtime(
        Hecksagain::Runtime::Dispatcher.new(registry)
      )
    end
  end

  def boot_banking = boot(RULES_BANKING)
  def boot_till    = boot(RULES_TILL)

  def funded_account(runtime)
    runtime.dispatch("Banking::Customer.Register", reference: { value: "c" },
                     name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
    runtime.dispatch("Banking::Account.Open", customer_id: { value: "c" }, number: { value: "a1" },
                                              kind: { name: "current" }, daily_limit: { cents: 50_000 })
    runtime.dispatch("Banking::Account.Credit", number: { value: "a1" }, amount: { cents: 10_000, currency: "USD" }, narrative: { text: "Opening" })
    runtime
  end

  def narrative = { text: "Corrected" }

  describe "Integer-or-nothing arithmetic" do
    it "refuses a non-Integer amount on a RECORD, in so many words" do
      runtime = boot_till
      runtime.dispatch("TillRoom::Till.OpenTill", number: { value: "till-1" })

      expect do
        runtime.dispatch("TillRoom::Till.TakeIn", number: { value: "till-1" }, amount: "a lot")
      end.to raise_error(Hecksagain::Runtime::TypeMismatch, /pass its fields as an object/)
    end

    it "refuses a non-Integer amount on an ELEMENT, in the same words" do
      runtime = funded_account(boot_banking)

      expect do
        runtime.dispatch("Banking::Account.LedgerEntry.Amend",
                         number: { value: "a1" }, sequence: { value: 1 }, adjustment: { cents: "a lot", currency: "USD" }, narrative: narrative)
      end.to raise_error(Hecksagain::Runtime::TypeMismatch,
                         'Money.cents expects Integer, got "a lot"')
    end

    it "moves an element by exactly what it was told" do
      runtime = funded_account(boot_banking)
      runtime.dispatch("Banking::Account.LedgerEntry.Amend",
                       number: { value: "a1" }, sequence: { value: 1 }, adjustment: { cents: 500, currency: "USD" }, narrative: narrative)

      entry = runtime.query("Banking::Account.LedgerEntry.Reversed")
      expect(entry).to be_empty 

      state = runtime.dispatch("Banking::Account.LedgerEntry.Amend",
                               number: { value: "a1" }, sequence: { value: 1 }, adjustment: { cents: -200, currency: "USD" }, narrative: narrative)
                     .state
      expect(state[:ledger].first[:amount].to_h).to eq(cents: 10_300, currency: "USD")
    end

    it "decrements an element by the same rule, not a sign it invented" do
      runtime = funded_account(boot_banking)
      state   = runtime.dispatch("Banking::Account.LedgerEntry.Amend",
                                 number: { value: "a1" }, sequence: { value: 1 }, adjustment: { cents: -1_000, currency: "USD" }, narrative: narrative)
                       .state

      expect(state[:ledger].first[:amount].to_h).to eq(cents: 9_000, currency: "USD")
    end

    it "refuses an amendment that would make an entry negative" do
      runtime = funded_account(boot_banking)

      expect do
        runtime.dispatch("Banking::Account.LedgerEntry.Amend",
                         number: { value: "a1" }, sequence: { value: 1 }, adjustment: { cents: -10_001, currency: "USD" }, narrative: narrative)
      end.to raise_error(Hecksagain::Runtime::GivenNotMet,
                         "Amend refused — an amendment leaves a non-negative amount")
    end
  end

  describe "the state machine" do
    it "refuses a move an AGGREGATE's machine does not admit" do
      runtime = funded_account(boot_banking)
      runtime.dispatch("Banking::Account.Freeze", number: { value: "a1" }, id: "a1")

      expect do
        runtime.dispatch("Banking::Account.Freeze", number: { value: "a1" }, id: "a1")
      end.to raise_error(Hecksagain::Runtime::LifecycleRefused,
                         'Freeze refused — status is "frozen", and Freeze moves it only from "open"')
    end

    it "refuses a move an ENTITY's own machine does not admit, in the same shape" do
      runtime = funded_account(boot_banking)
      runtime.dispatch("Banking::Account.LedgerEntry.Reverse",
                       number: { value: "a1" }, sequence: { value: 1 }, narrative: narrative)

      expect do
        runtime.dispatch("Banking::Account.LedgerEntry.Amend",
                         number: { value: "a1" }, sequence: { value: 1 }, adjustment: { cents: 100, currency: "USD" }, narrative: narrative)
      end.to raise_error(Hecksagain::Runtime::LifecycleRefused,
                         'Amend refused — state is "reversed", and Amend moves it only from "posted"')
    end

    it "does not settle a transfer until its destination credit is recorded" do
      runtime = boot_banking
      runtime.dispatch("Banking::Customer.Register", reference: { value: "c-src" },
                       name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
      runtime.dispatch("Banking::Account.Open", number: { value: "src" }, customer_id: { value: "c-src" },
                       kind: { name: "current" }, daily_limit: { cents: 50_000 })
      runtime.dispatch("Banking::Customer.Register", reference: { value: "c-dst" },
                       name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
      runtime.dispatch("Banking::Account.Open", number: { value: "dst" }, customer_id: { value: "c-dst" },
                       kind: { name: "current" }, daily_limit: { cents: 50_000 })
      runtime.dispatch("Banking::Transfer.Request",
                       id: "x1", source: { value: "src" }, destination: { value: "dst" },
                       amount: { cents: 100 }, narrative: { text: "A transfer waiting for credit" })
      runtime.dispatch("Banking::Transfer.Debited", transfer: "x1")

      expect do
        runtime.dispatch("Banking::Transfer.Settle", transfer: "x1")
      end.to raise_error(Hecksagain::Runtime::LifecycleRefused,
                         'Settle refused — status is "debited", and Settle moves it only from "credited"')
    end

    it "refuses duplicate and out-of-order transfer legs without changing their state" do
      runtime = boot_banking
      runtime.dispatch("Banking::Customer.Register", reference: { value: "c-src" },
                       name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
      runtime.dispatch("Banking::Account.Open", number: { value: "src" }, customer_id: { value: "c-src" },
                       kind: { name: "current" }, daily_limit: { cents: 50_000 })
      runtime.dispatch("Banking::Customer.Register", reference: { value: "c-dst" },
                       name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
      runtime.dispatch("Banking::Account.Open", number: { value: "dst" }, customer_id: { value: "c-dst" },
                       kind: { name: "current" }, daily_limit: { cents: 50_000 })
      runtime.dispatch("Banking::Transfer.Request",
                       id: "x1", source: { value: "src" }, destination: { value: "dst" },
                       amount: { cents: 100 }, narrative: { text: "An ordered transfer" })

      expect { runtime.dispatch("Banking::Transfer.Settle", transfer: "x1") }
        .to raise_error(Hecksagain::Runtime::LifecycleRefused, /status is "requested"/)

      runtime.dispatch("Banking::Transfer.Debited", transfer: "x1")
      runtime.dispatch("Banking::Transfer.Credited", transfer: "x1")

      expect { runtime.dispatch("Banking::Transfer.Credited", transfer: "x1") }
        .to raise_error(Hecksagain::Runtime::LifecycleRefused,
                        'Credited refused — status is "credited", and Credited moves it only from "debited"')
      expect(runtime.registry.repository("Banking", runtime.registry.bluebook("Banking").aggregate("Transfer"))
                    .find("x1")[:status]).to eq("credited")
    end
  end

  describe "the rules have one home" do
    it "leaves each interpreter with one verb" do
      surface = lambda do |klass|
        klass.public_instance_methods(false).sort - [:registry]
      end

      expect(surface[Hecksagain::Runtime::CommandInterpreter]).to eq([:call])
      expect(surface[Hecksagain::Runtime::EntityInterpreter]).to  eq([:call])
      expect(surface[Hecksagain::Runtime::QueryInterpreter]).to   eq([:call])
      expect(surface[Hecksagain::Runtime::PolicyInterpreter]).to  eq([:react])
      expect(surface[Hecksagain::Runtime::SagaInterpreter]).to    eq([:advance])
    end
  end
end
