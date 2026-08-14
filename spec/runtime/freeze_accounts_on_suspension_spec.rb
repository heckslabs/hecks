
require "spec_helper"

# ONE REAL BUG FIXED HERE; TWO MORE FOUND AND DELIBERATELY LEFT OPEN —
# found wiring `for_each` into banking for the first time (this
# session's own property-testing arc), not a hypothetical.
# `FreezeAccountsOnSuspension` has refused every dispatch, silently,
# since the day it was written. See banking.bluebook's own comment on
# the policy for the full account; the short version:
#
#   FIXED — the ADDRESSING BUG. `for_each` used to hardcode
#   `<aggregate>_id` for every fan-out target unconditionally
#   (`Behaviour::Policy#fan_out_reference_key`, since deleted).
#   `Account.Freeze` self-references Account and is addressed by
#   `account`, not `account_id` — the same self-vs-foreign-key
#   distinction `Customer.Suspend`'s own `reference` argument already
#   demonstrates elsewhere in the corpus.
#   `Behaviour::Command#addressing_key_for`, asked of the resolved
#   TARGET command rather than guessed from the aggregate name alone,
#   fixes this — verified below, and confirmed Rust-conformance-safe
#   (a pure interpreter change, no new declared IR).
#
#   STILL OPEN — wholesale payload forwarding. `Account.Freeze` still
#   declares neither `reference` nor `standing`, which
#   `deliver_for_each_row` still forwards wholesale from
#   CustomerSuspended's own payload. An unused pass-through attribute
#   (the fix `Account.Review`'s own `customer_id`/`risk` already use
#   elsewhere) was tried and reverted — it trips a real Rust codegen
#   gap: Rust serializes every declared attribute into an emitted
#   event's payload, `null` for one never supplied, where Ruby
#   serializes only what was actually in `args`. A Rust codegen
#   question, not fixed here.
#
#   STILL OPEN — a business-rule contradiction, independent of the
#   above: `Account.Freeze`'s own `given("customer is active")` cannot
#   be satisfied by the one reaction that exists to invoke it. A real
#   domain decision, not guessed at here.
#
# So: the account is still not frozen today, same as before this fix —
# but the FAN-OUT ITSELF is now demonstrably correct (right accounts,
# right addressing key, right scoping), which the first spec pins.
RSpec.describe "FreezeAccountsOnSuspension" do
  def build
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook"))
      Hecks.hecksagon("Banking") do
        Banking::Customer.persisted_by("Memory")
        Banking::Account.persisted_by("Memory")
        Banking::ATMCard.persisted_by("Memory")
        Banking::Transfer.persisted_by("Memory")
        Banking::CardPayment.persisted_by("Memory")
        Banking::ExternalTransfer.persisted_by("Memory")
        Banking::ScheduledPayment.persisted_by("Memory")
        Banking::SafeDepositBox.persisted_by("Memory")
        Banking::OnboardingCase.persisted_by("Memory")
      end
    end
    registry.verify!
    Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
  end

  it "fans out to every one of the RIGHT customer's own open accounts — the addressing bug, fixed" do
    runtime = build
    runtime.dispatch("Banking::Customer.Register", reference: { value: "CUST-0001" },
                                                     name: { given: "Ada", family: "Lovelace" },
                                                     email: { address: "ada@example.com" })
    runtime.dispatch("Banking::Customer.Register", reference: { value: "CUST-0002" },
                                                     name: { given: "Grace", family: "Hopper" },
                                                     email: { address: "grace@example.com" })
    runtime.dispatch("Banking::Account.Open", customer_id: "CUST-0001", number: { value: "acct-1" },
                                               kind: { name: "current" }, daily_limit: { cents: 50_000 })
    runtime.dispatch("Banking::Account.Open", customer_id: "CUST-0001", number: { value: "acct-1b" },
                                               kind: { name: "savings" }, daily_limit: { cents: 50_000 })
    runtime.dispatch("Banking::Account.Open", customer_id: "CUST-0002", number: { value: "acct-2" },
                                               kind: { name: "current" }, daily_limit: { cents: 50_000 })

    runtime.dispatch("Banking::Customer.Suspend", reference: { value: "CUST-0001" },
                                                   standing: { value: "chargeback investigation" })

    reactions = runtime.reactions.select { |r| r[:policy] == "FreezeAccountsOnSuspension" }
    # BOTH of CUST-0001's own accounts, and ONLY those — acct-2 belongs
    # to a different customer and the fan-out correctly never touches it.
    # If this ever asserts "does not declare account_id" again, the
    # addressing fix regressed; it should always be exactly the
    # wholesale-forwarding refusal now (a SEPARATE, still-open issue —
    # see this file's own header).
    expect(reactions.map { |r| r[:for_row] }.sort).to eq(%w[acct-1 acct-1b])
    reactions.each do |reaction|
      expect(reaction).to include(delivered: false)
      expect(reaction[:reason]).to eq("Freeze does not declare standing — it takes ")
    end

    repository = runtime.registry.repository("Banking", runtime.registry.bluebook("Banking").aggregate("Account"))
    expect(repository.find("acct-1").state[:status]).to eq("open")
    expect(repository.find("acct-1b").state[:status]).to eq("open")
    expect(repository.find("acct-2").state[:status]).to eq("open") # untouched — different customer
  end

  it "Account.OpenForCustomer answers correctly on its own — the for_each target, scoped to ONE customer" do
    runtime = build
    runtime.dispatch("Banking::Customer.Register", reference: { value: "CUST-0001" },
                                                     name: { given: "Ada", family: "Lovelace" },
                                                     email: { address: "ada@example.com" })
    runtime.dispatch("Banking::Customer.Register", reference: { value: "CUST-0002" },
                                                     name: { given: "Grace", family: "Hopper" },
                                                     email: { address: "grace@example.com" })
    runtime.dispatch("Banking::Account.Open", customer_id: "CUST-0001", number: { value: "acct-1" },
                                               kind: { name: "current" }, daily_limit: { cents: 50_000 })
    runtime.dispatch("Banking::Account.Open", customer_id: "CUST-0002", number: { value: "acct-2" },
                                               kind: { name: "current" }, daily_limit: { cents: 50_000 })

    rows = runtime.query("Banking::Account.OpenForCustomer", reference: { value: "CUST-0001" })

    expect(rows.map { |row| row[:id] }).to eq(["acct-1"]) # not acct-2 — scoped to the right customer, not every open account
  end
end
