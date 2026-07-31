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
    20.times do |seed|
      runtime = boot_banking
      runtime.dispatch("Banking::Customer.Register", reference: { value: "c" },
                       name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
      runtime.dispatch("Banking::Account.Open", customer_id: "c", number: { value: "a#{seed}" },
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
end
