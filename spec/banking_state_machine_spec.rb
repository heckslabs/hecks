require "spec_helper"

RSpec.describe "Banking's generated account machine" do
  STATE_MACHINE_BLUEBOOK = File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook")

  def boot_banking
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(STATE_MACHINE_BLUEBOOK)
      Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
    end
  end

  it "preserves the account balance invariant across deterministic command traces" do
    # Booted ONCE, not once per seed — each seed only ever collides with
    # ITSELF (a distinct customer ref and a distinct account number), so
    # 20 independent traces can run against one shared runtime instead of
    # 20 fresh ~100ms boots. The invariant this checks is per-account
    # (`stored` below is looked up by this seed's own account number),
    # so nothing about sharing the runtime changes what's being proven.
    runtime = boot_banking

    20.times do |seed|
      runtime.dispatch("Banking::Customer.Register", reference: { value: "c#{seed}" },
                       name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
      runtime.dispatch("Banking::Account.Open", customer: "c#{seed}", number: { value: "a#{seed}" },
                                                kind: { name: "current" }, daily_limit: { cents: 1_000 })
      model = 0
      random = Random.new(seed)

      50.times do
        amount = random.rand(-200..1_200)
        verb   = random.rand(2).zero? ? "Credit" : "Debit"
        before = model

        begin
          runtime.dispatch("Banking::Account.#{verb}", number: { value: "a#{seed}" }, amount: { cents: amount, currency: "USD" },
                                                        narrative: { text: "generated #{seed}" })
          model += verb == "Credit" ? amount : -amount
        rescue Hecksagain::Runtime::GivenNotMet, Hecksagain::Runtime::InvariantViolation
          model = before
        end

        stored = runtime.registry.repository("Banking", runtime.registry.bluebook("Banking").aggregate("Account"))
                        .find("a#{seed}")
        expect(stored[:balance].to_h).to eq(cents: model, currency: "USD")
        expect(stored[:balance].cents).to be >= 0
      end
    end
  end

  # NEGATIVE CONTROL for MutationApplier#check_entity_collision — LedgerEntry
  # is `identified_by :sequence`, but Credit/Debit's own `sets :ledger,
  # append: { amount: ..., narrative: ... }` never names `sequence`, so it
  # always takes the AUTO-MINT branch (`current.size + 1`), never the
  # collision-checked one. Two IDENTICAL Credits (same amount, same
  # narrative — everything but the auto-minted sequence collides) must both
  # land, not be refused as duplicates.
  it "never flags an auto-minted entity list as colliding, even with identical repeated writes" do
    runtime = boot_banking
    runtime.dispatch("Banking::Customer.Register", reference: { value: "c1" },
                     name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
    runtime.dispatch("Banking::Account.Open", customer: "c1", number: { value: "a1" },
                                              kind: { name: "current" }, daily_limit: { cents: 1_000 })

    3.times do
      runtime.dispatch("Banking::Account.Credit", number: { value: "a1" }, amount: { cents: 100, currency: "USD" },
                                                   narrative: { text: "same narrative every time" })
    end

    stored = runtime.registry.repository("Banking", runtime.registry.bluebook("Banking").aggregate("Account"))
                    .find("a1")
    expect(stored[:ledger].size).to eq(3)
    expect(stored[:ledger].map { |entry| entry[:sequence].to_h }).to eq([{ value: 1 }, { value: 2 }, { value: 3 }])
  end
end
