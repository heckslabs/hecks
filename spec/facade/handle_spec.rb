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
        ::Banking::SafeDepositBox.persisted_by("Memory")
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

  # `Handle#run` used to address every non-creating verb with
  # `{ @ir.identified_by => @id }` — `identified_by` is nil the moment an
  # identity is composite, so this built `{ nil => @id }`, and dispatch's
  # own argument gate crashed on `nil.to_sym` reading the args back (worse
  # still on a zero-attribute command like `Surrender`, where that stray nil
  # key was the ONLY thing in the payload). `SafeDepositBox`'s
  # `branch_code`/`box_number` identity is banking's one composite head,
  # so it is what proves door sugar addresses a multi-part identity, not
  # just a single one.
  it "dispatches non-creating verbs on a composite-identity aggregate" do
    boot_banking_in_memory

    Banking::Customer.register(reference: { value: "c1" }, name: { given: "Ada", family: "Lovelace" },
                                email: { address: "ada@example.com" })
    box = Banking::SafeDepositBox.rent(customer_id: "c1", branch_code: { value: "BR01" },
                                        box_number: { value: 12 }, size: { value: "small" })

    box.log_visit(date: { value: "2026-08-04" }, sequence: { value: 1 })
    expect(box[:visits].size).to eq(1)

    box.issue_key(serial: { value: "K1" })
    expect(box[:keys].size).to eq(1)

    # Zero declared attributes — the identity payload is the ENTIRE args
    # hash, so a stray `nil` key had nowhere to hide.
    box.surrender
    expect(box.status).to eq("vacant")
  end
end
