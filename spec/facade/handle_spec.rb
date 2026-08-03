require "spec_helper"

RSpec.describe Hecksagain::Facade::Handle do
  BANKING_BLUEBOOK = File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook")

  def boot_banking_in_memory
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(BANKING_BLUEBOOK)

      Hecks.hecksagon("Banking") do
        ::Banking::Customer.persisted_by("Memory")
        ::Banking::Account.persisted_by("Memory")
      end
    end

    registry.verify!
    Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
  end

  # A non-creating verb whose snake-cased name collides with a real
  # Object/Kernel method (`Account.Freeze` -> `freeze`) used to be silently
  # swallowed by Kernel#freeze rather than dispatched — no error, no
  # refusal, the transition just never happened.
  it "dispatches a verb even when its name collides with a Kernel method" do
    boot_banking_in_memory

    customer = Banking::Customer.register(
      reference: { value: "c1" },
      name: { given: "Ada", family: "Lovelace" },
      email: { address: "ada@example.com" }
    )
    account = Banking::Account.open(
      customer_id: customer.id,
      number: { value: "a1" },
      kind: { name: "current" },
      daily_limit: { cents: 1_000 }
    )

    expect(account.status).to eq("open")

    account.freeze

    expect(account.status).to eq("frozen")
    expect(account.frozen?).to be(false)
    expect(account.events.map(&:name)).to include("AccountFrozen")

    # Chains cleanly, the way every other non-creating verb does — a truly
    # Kernel-frozen object would raise FrozenError the moment `run` tried to
    # reassign @state.
    account.unfreeze
    expect(account.status).to eq("open")
  end
end
