
require "spec_helper"

# A REAL, CURRENTLY-OPEN BUG — found wiring `for_each` into banking for
# the first time (this session's own property-testing arc), not a
# hypothetical. `FreezeAccountsOnSuspension` has refused EVERY dispatch,
# silently, since the day it was written: `CustomerSuspended`'s own
# payload (`{reference:, standing:}` — Customer's own fields) forwards
# wholesale into `Account.Freeze`, which wants neither. The name is
# plural ("Accounts") but the mechanism only ever attempted ONE
# dispatch, with the wrong shape — no account has ever actually been
# frozen by this policy.
#
# `for_each "Account.OpenForCustomer"` looked like the fix (the query
# below was added specifically for it) but does NOT close this — see
# banking.bluebook's own comment on the policy for why:
# `PolicyInterpreter#deliver_for_each_row`'s reference-key mint
# (`Behaviour::Policy#fan_out_reference_key`) hardcodes `<aggregate>_id`
# for every fan-out target, but `Account` is addressed by `number`
# (`identified_by AccountNumber, as: :number`), not `account_id`, for a
# self-referencing command like `Freeze`. Closing this needs a runtime
# change, not a domain-content one — deliberately NOT made here.
#
# This spec pins BOTH halves: the bug that has always been there (still
# open), and the new query that exists and works correctly on its own,
# scoped to one customer, ready for whichever fix eventually lands.
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

  it "STILL refuses every account it should freeze — the open bug, pinned so a fix has to touch this spec" do
    runtime = build
    runtime.dispatch("Banking::Customer.Register", reference: { value: "CUST-0001" },
                                                     name: { given: "Ada", family: "Lovelace" },
                                                     email: { address: "ada@example.com" })
    runtime.dispatch("Banking::Account.Open", customer_id: "CUST-0001", number: { value: "acct-1" },
                                               kind: { name: "current" }, daily_limit: { cents: 50_000 })

    runtime.dispatch("Banking::Customer.Suspend", reference: { value: "CUST-0001" },
                                                   standing: { value: "chargeback investigation" })

    reaction = runtime.reactions.find { |r| r[:policy] == "FreezeAccountsOnSuspension" }
    expect(reaction).to include(delivered: false)
    expect(reaction[:reason]).to match(/Freeze does not declare/)

    account = runtime.registry.repository("Banking", runtime.registry.bluebook("Banking").aggregate("Account")).find("acct-1")
    expect(account.state[:status]).to eq("open"), "the account was never actually frozen — the bug this spec pins"
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
