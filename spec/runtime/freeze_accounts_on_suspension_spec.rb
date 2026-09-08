require "spec_helper"

# TWO REAL BUGS FIXED; TWO MORE FOUND, BOTH GENUINELY BIGGER, BOTH
# DELIBERATELY LEFT OPEN — found wiring `for_each` into banking for the
# first time (this session's own property-testing arc), not a
# hypothetical. `FreezeAccountsOnSuspension` has refused every dispatch,
# silently, since it was written. See banking.bluebook's own comment on
# the policy for the full account; the short version:
#
#   FIXED — the ADDRESSING BUG (`Behaviour::Command#addressing_key_for`,
#   pinned directly in spec/bluebook/behaviour/command_addressing_key_
#   spec.rb — no live policy needs to exercise it for that spec to hold).
#
#   FIXED — the BUSINESS-RULE CONTRADICTION (`Account.FreezeAccount`'s own
#   given, "customer is active" -> "customer is not closed", matching
#   `Account.CloseAccount`'s own established idiom — verified directly
#   below).
#
#   STILL OPEN — wholesale payload forwarding, AND, discovered only once
#   the two fixes above let this policy's own for_each dispatch actually
#   succeed for the first time in Ruby: `hecks-parse` does not parse
#   `where`/`for_each` on a `Policy` at all (a known, tracked Stage-1
#   gap — but `examples/banking` is a `REAL_PARITY_MEMBERS` domain, held
#   to full byte-exact parser parity, so it can't be the corpus member
#   that closes this), and separately, `bin/project_rust`'s own
#   generated Rust kernel dispatch doesn't implement `for_each` fan-out
#   AT ALL (`PolicyRule` carries no such field). Both real, both much
#   bigger than this session's own two fixes, both flagged rather than
#   attempted. `for_each` therefore stays UNWIRED on the real policy —
#   `FreezeAccountsOnSuspension` is back to a plain `trigger`, same as
#   it always was, still refusing on the wholesale-forwarding question
#   for the ORIGINAL reason.
RSpec.describe "FreezeAccountsOnSuspension" do
  def build
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
      Hecks.hecksagon("Banking") do
        uses_framework "Governance"
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
      Hecks.hecksagon("Governance") do
        Governance::RoleAssignment.persisted_by("Memory")
        Governance::RoleTransition.persisted_by("Memory")
      end
    end
    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  it "freezes every open account the suspended customer holds, and only theirs" do
    runtime = build
    runtime.dispatch("Banking::Customer.Register", reference: { value: "CUST-0001" },
                                                   name:      { given: "Ada", family: "Lovelace" },
                                                   email:     { address: "ada@example.com" })
    runtime.dispatch("Banking::Account.Open", customer: "CUST-0001", number: { value: "acct-1" },
                                               kind: { name: "current" }, daily_limit: { cents: 50_000 })

    runtime.dispatch("Banking::Account.Open", customer: "CUST-0001", number: { value: "acct-2" },
                                               kind: { name: "savings" }, daily_limit: { cents: 10_000 })

    runtime.dispatch("Banking::Customer.Suspend", reference: { value: "CUST-0001" },
                                                  standing:  { value: "chargeback investigation" })

    fan = runtime.reactions.select { |r| r[:policy] == "FreezeAccountsOnSuspension" }
    expect(fan.map { |r| r[:for_row] }).to contain_exactly("acct-1", "acct-2")
    expect(fan).to all(include(delivered: true))

    repository = runtime.registry.repository("Banking", runtime.registry.bluebook("Banking").aggregate("Account"))
    expect(repository.find("acct-1").state[:status]).to eq("frozen")
    expect(repository.find("acct-2").state[:status]).to eq("frozen")
  end

  # THE REFUSAL THIS USED TO ASSERT. `with: { account: :account }` is
  # what closed it — without a projection the whole `CustomerSuspended`
  # payload rode along, and `FreezeAccount` (which declares no arguments
  # at all) refused every row with `does not declare standing`.
  it "hands the trigger the row and nothing else, so the event's own fields never reach it" do
    runtime = build
    runtime.dispatch("Banking::Customer.Register", reference: { value: "CUST-0001" },
                                                   name:      { given: "Ada", family: "Lovelace" },
                                                   email:     { address: "ada@example.com" })
    runtime.dispatch("Banking::Account.Open", customer: "CUST-0001", number: { value: "acct-1" },
                                               kind: { name: "current" }, daily_limit: { cents: 50_000 })

    runtime.dispatch("Banking::Customer.Suspend", reference: { value: "CUST-0001" },
                                                  standing:  { value: "chargeback investigation" })

    fan = runtime.reactions.select { |r| r[:policy] == "FreezeAccountsOnSuspension" }
    expect(fan.filter_map { |r| r[:reason] }).to be_empty
  end

  it "Account.OpenForCustomer answers correctly on its own — the for_each target, scoped to ONE customer, " \
     "ready for whichever gap closes first" do
    runtime = build
    runtime.dispatch("Banking::Customer.Register", reference: { value: "CUST-0001" },
                                                   name:      { given: "Ada", family: "Lovelace" },
                                                   email:     { address: "ada@example.com" })
    runtime.dispatch("Banking::Customer.Register", reference: { value: "CUST-0002" },
                                                   name:      { given: "Grace", family: "Hopper" },
                                                   email:     { address: "grace@example.com" })
    runtime.dispatch("Banking::Account.Open", customer: "CUST-0001", number: { value: "acct-1" },
                                               kind: { name: "current" }, daily_limit: { cents: 50_000 })
    runtime.dispatch("Banking::Account.Open", customer: "CUST-0002", number: { value: "acct-2" },
                                               kind: { name: "current" }, daily_limit: { cents: 50_000 })

    rows = runtime.query("Banking::Account.OpenForCustomer", reference: { value: "CUST-0001" })

    expect(rows.map { |row| row[:id] }).to eq(["acct-1"]) # not acct-2 — scoped to the right customer, not every open account
  end

  # THE BUSINESS RULE ITSELF, pinned independently of any reaction.
  #
  # This used to dispatch `FreezeAccount` DIRECTLY against a suspended
  # customer's open account, to prove the given in isolation. That state
  # is no longer reachable: the policy freezes every open account the
  # moment its customer is suspended, `Account.Open` refuses a suspended
  # customer, and `Unfreeze` refuses one too — so "an open account
  # belonging to a suspended customer" cannot be constructed at all any
  # more, which is the domain working rather than the test decaying.
  #
  # What remains checkable is the rule as declared, plus the behaviour
  # above: the policy's own fan-out succeeding IS the given admitting a
  # suspended customer, since nothing else could have let it through.
  it "guards on the relationship being open, not on the customer being active" do
    runtime = build
    freeze = runtime.registry.bluebook("Banking").aggregate("Account").command("FreezeAccount")

    # "account is open" — S10, ADR 0025 — is now a lifecycle guard
    # (command "FreezeAccount", from: "open"), not a given; the given
    # list carries only the rule no lifecycle field can check.
    expect(freeze.givens.map(&:description)).to eq(["customer is not closed"])
    expect(freeze.from).to eq("open")
  end
end
