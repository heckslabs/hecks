require "spec_helper"

RSpec.describe "the rules a command obeys" do
  RULES_BANKING = InMemoryDomain::BANKING_BLUEBOOK_DIR
  RULES_TILL    = File.join(InMemoryDomain::ROOT, "spec/fixtures/till.bluebook")

  def boot(bluebook)
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(bluebook)
      Hecks::Runtime::Loader.bind_runtime(
        Hecks::Runtime::Dispatcher.new(registry)
      )
    end
  end

  def boot_banking = boot(RULES_BANKING)
  def boot_till    = boot(RULES_TILL)

  def funded_account(runtime)
    runtime.dispatch_flat("Banking::Customer.Register", reference: { value: "c" },
                     name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
    runtime.dispatch_flat("Banking::Account.Open", customer: "c", number: { value: "a1" },
                                              kind: { name: "current" }, daily_limit: { cents: 50_000 })
    runtime.dispatch_flat("Banking::Account.Credit", number: { value: "a1" }, amount: { cents: 10_000, currency: "USD" },
narrative: { text: "Opening" })
    runtime
  end

  def narrative = { text: "Corrected" }

  describe "Integer-or-nothing arithmetic" do
    # Money is a single-field value object, so a bare scalar auto-wraps to `{ cents: "a lot" }`
    # and refuses at `check_numeric_fields`, naming the field and type.
    it "refuses a non-Integer amount on a RECORD, in so many words" do
      runtime = boot_till
      runtime.dispatch_flat("TillRoom::Till.OpenTill", number: { value: "till-1" })

      expect do
        runtime.dispatch_flat("TillRoom::Till.TakeIn", number: { value: "till-1" }, amount: "a lot")
      end.to raise_error(Hecks::Runtime::TypeMismatch, 'Money.cents expects Integer, got "a lot"')
    end

    it "refuses a non-Integer amount on an ELEMENT, in the same words" do
      runtime = funded_account(boot_banking)

      expect do
        runtime.dispatch_flat("Banking::Account.LedgerEntry.Amend",
                              number: { value: "a1" }, sequence: { value: 1 },
                              adjustment: { cents: "a lot", currency: "USD" }, narrative: narrative)
      end.to raise_error(Hecks::Runtime::TypeMismatch,
                         'Money.cents expects Integer, got "a lot"')
    end

    # An absent argument is nil, not its own name: falling through to the Symbol in
    # `resolve_source` would hand coercion `:amount` and refuse with a wrong-shape message.
    it "says an absent OPTIONAL argument is nil, not the name of the argument" do
      runtime = boot_till
      runtime.dispatch_flat("TillRoom::Till.OpenTill", number: { value: "till-1" })

      # `note` is optional, so the payload gate passes and the mutation resolves an absent arg;
      # resolving it to `:note` would refuse with a misleading "pass its fields as an object".
      state = runtime.dispatch_flat("TillRoom::Till.TakeIn",
                                    number: { value: "till-1" }, amount: { cents: 300 }).state

      expect(state[:note]).to be_nil
      expect(state[:balance].to_h).to eq(cents: 300)
    end

    it "refuses an absent REQUIRED argument at the gate, before any rule runs" do
      runtime = funded_account(boot_banking)

      expect do
        runtime.dispatch_flat("Banking::Account.Credit",
                              number: { value: "a1" }, narrative: { text: "No amount at all" })
      end.to raise_error(Hecks::Runtime::AbsentArgument,
                         "Credit was not given amount — it takes amount, narrative")
    end

    # An unset total reads as zero (`current ||= 0`); an absent amount is a caller's mistake.
    # Conflating them would let an absent amount increment by zero and succeed.
    it "still starts an unset total at zero" do
      runtime = funded_account(boot_banking)
      state   = runtime.dispatch_flat("Banking::Account.ApplyFee",
                                      number: { value: "a1" }, amount: { cents: 250, currency: "USD" },
                                      narrative: narrative)
                       .state

      expect(state[:fees_cents].to_h).to eq(cents: 250, currency: "USD")
    end

    it "moves an element by exactly what it was told" do
      runtime = funded_account(boot_banking)
      runtime.dispatch_flat("Banking::Account.LedgerEntry.Amend",
                            number: { value: "a1" }, sequence: { value: 1 },
                            adjustment: { cents: 500, currency: "USD" }, narrative: narrative)

      entry = runtime.query("Banking::Account.LedgerEntry.Reversed")
      expect(entry).to be_empty

      state = runtime.dispatch_flat("Banking::Account.LedgerEntry.Amend",
                                    number: { value: "a1" }, sequence: { value: 1 },
                                    adjustment: { cents: -200, currency: "USD" }, narrative: narrative)
                     .state
      expect(state[:ledger].first[:amount].to_h).to eq(cents: 10_300, currency: "USD")
    end

    it "decrements an element by the same rule, not a sign it invented" do
      runtime = funded_account(boot_banking)
      state   = runtime.dispatch_flat("Banking::Account.LedgerEntry.Amend",
                                      number: { value: "a1" }, sequence: { value: 1 },
                                      adjustment: { cents: -1_000, currency: "USD" }, narrative: narrative)
                       .state

      expect(state[:ledger].first[:amount].to_h).to eq(cents: 9_000, currency: "USD")
    end

    it "refuses an amendment that would make an entry negative" do
      runtime = funded_account(boot_banking)

      expect do
        runtime.dispatch_flat("Banking::Account.LedgerEntry.Amend",
                              number: { value: "a1" }, sequence: { value: 1 },
                              adjustment: { cents: -10_001, currency: "USD" }, narrative: narrative)
      end.to raise_error(Hecks::Runtime::GivenNotMet,
                         "Amend refused — an amendment leaves a non-negative amount")
    end

    it "carries the failing comparison's own operands as #detail, off #message" do
      runtime = funded_account(boot_banking)

      error = nil
      begin
        runtime.dispatch_flat("Banking::Account.LedgerEntry.Amend",
                              number: { value: "a1" }, sequence: { value: 1 },
                              adjustment: { cents: -10_001, currency: "USD" }, narrative: narrative)
      rescue Hecks::Runtime::GivenNotMet => e
        error = e
      end

      expect(error.message).to eq("Amend refused — an amendment leaves a non-negative amount")
      expect(error.detail).to eq("left: -1, right: 0")
      expect(error.detailed_message).to include(error.message).and include(error.detail)
    end
  end

  describe "the state machine" do
    it "refuses a move an AGGREGATE's machine does not admit" do
      runtime = funded_account(boot_banking)
      runtime.dispatch_flat("Banking::Account.FreezeAccount", number: { value: "a1" }, id: "a1")

      # A real lifecycle guard (`command "FreezeAccount", from: "open"`, ADR 0025) runs in
      # `enforce_givens`; an already-frozen account is refused by state name.
      expect do
        runtime.dispatch_flat("Banking::Account.FreezeAccount", number: { value: "a1" }, id: "a1")
      end.to raise_error(Hecks::Runtime::LifecycleRefused,
                         'FreezeAccount refused — status is "frozen", and FreezeAccount moves it only from "open"')
    end

    it "refuses a move an ENTITY's own machine does not admit, in the same shape" do
      runtime = funded_account(boot_banking)
      runtime.dispatch_flat("Banking::Account.LedgerEntry.Reverse",
                            number: { value: "a1" }, sequence: { value: 1 }, narrative: narrative)

      # Amend's `given("entry is posted")` pre-empts the entity's lifecycle machine
      # (`admissible_transition` runs after `enforce_givens`): GivenNotMet, not LifecycleRefused.
      expect do
        runtime.dispatch_flat("Banking::Account.LedgerEntry.Amend",
                              number: { value: "a1" }, sequence: { value: 1 },
                              adjustment: { cents: 100, currency: "USD" }, narrative: narrative)
      end.to raise_error(Hecks::Runtime::GivenNotMet, "Amend refused — entry is posted")
    end

    it "does not settle a transfer until its destination credit is recorded" do
      runtime = boot_banking
      runtime.dispatch_flat("Banking::Customer.Register", reference: { value: "c-src" },
                       name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
      runtime.dispatch_flat("Banking::Account.Open", number: { value: "src" }, customer: "c-src",
                       kind: { name: "current" }, daily_limit: { cents: 50_000 })
      runtime.dispatch_flat("Banking::Customer.Register", reference: { value: "c-dst" },
                       name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
      runtime.dispatch_flat("Banking::Account.Open", number: { value: "dst" }, customer: "c-dst",
                       kind: { name: "current" }, daily_limit: { cents: 50_000 })
      runtime.dispatch_flat("Banking::Transfer.Request",
                            reference: { value: "x1" }, source: "src", destination: "dst",
                            amount: { cents: 100 }, narrative: { text: "A transfer waiting for credit" })
      runtime.dispatch_flat("Banking::Transfer.Debited", transfer: "x1")

      # ADR 0025: Settle's `from: "credited"` guard refuses (LifecycleRefused) before any credit.
      expect do
        runtime.dispatch_flat("Banking::Transfer.Settle", transfer: "x1")
      end.to raise_error(Hecks::Runtime::LifecycleRefused,
                         'Settle refused — status is "debited", and Settle moves it only from "credited"')
    end

    it "refuses duplicate and out-of-order transfer legs without changing their state" do
      runtime = boot_banking
      runtime.dispatch_flat("Banking::Customer.Register", reference: { value: "c-src" },
                       name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
      runtime.dispatch_flat("Banking::Account.Open", number: { value: "src" }, customer: "c-src",
                       kind: { name: "current" }, daily_limit: { cents: 50_000 })
      runtime.dispatch_flat("Banking::Customer.Register", reference: { value: "c-dst" },
                       name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
      runtime.dispatch_flat("Banking::Account.Open", number: { value: "dst" }, customer: "c-dst",
                       kind: { name: "current" }, daily_limit: { cents: 50_000 })
      runtime.dispatch_flat("Banking::Transfer.Request",
                            reference: { value: "x1" }, source: "src", destination: "dst",
                            amount: { cents: 100 }, narrative: { text: "An ordered transfer" })

      # ADR 0025: both commands guard with `from:`; each out-of-order point is LifecycleRefused.
      expect { runtime.dispatch_flat("Banking::Transfer.Settle", transfer: "x1") }
        .to raise_error(Hecks::Runtime::LifecycleRefused,
                        'Settle refused — status is "requested", and Settle moves it only from "credited"')

      runtime.dispatch_flat("Banking::Transfer.Debited", transfer: "x1")
      runtime.dispatch_flat("Banking::Transfer.Credited", transfer: "x1")

      expect { runtime.dispatch_flat("Banking::Transfer.Credited", transfer: "x1") }
        .to raise_error(Hecks::Runtime::LifecycleRefused,
                        'Credited refused — status is "credited", and Credited moves it only from "debited"')
      expect(runtime.registry.repository("Banking", runtime.registry.bluebook("Banking").aggregate("Transfer"))
                    .find("x1")[:status]).to eq("credited")
    end
  end

  # A `given`/`ensures` reading a related record's field (`customer.status`).
  # `CommandRules::References#dereference` resolves it into a plain Hash before evaluation,
  # for a declared reference, a command's reference argument, and the two-hop chain.
  describe "dereferencing a related record's field in given/ensures" do
    it "reads a stored aggregate-level reference's field, live — not a snapshot taken at dispatch time" do
      runtime = funded_account(boot_banking)

      expect do
        runtime.dispatch_flat("Banking::Account.Credit", number: { value: "a1" },
                         amount: { cents: 100, currency: "USD" }, narrative: { text: "before" })
      end.not_to raise_error

      runtime.dispatch_flat("Banking::Customer.Suspend", reference: { value: "c" },
                                                         standing:  { value: "chargeback investigation" })

      expect do
        runtime.dispatch_flat("Banking::Account.Credit", number: { value: "a1" },
                         amount: { cents: 100, currency: "USD" }, narrative: { text: "after" })
      end.to raise_error(Hecks::Runtime::GivenNotMet, "Credit refused — customer is active")
    end

    it "reads a command-level reference argument's field (one hop)" do
      runtime = funded_account(boot_banking)

      expect do
        runtime.dispatch_flat("Banking::ATMCard.Issue", account: "a1",
                         serial: { value: "s1" }, daily_fee: { amount: 100 })
      end.not_to raise_error
    end

    it "chains through a command-level reference into ITS OWN aggregate-level reference (two hops)" do
      runtime = funded_account(boot_banking)

      expect do
        runtime.dispatch_flat("Banking::CardPayment.Authorize", account: "a1",
                         authorisation: { value: "auth1" }, amount: { cents: 500 },
                         merchant: { value: "Merchant" })
      end.not_to raise_error

      runtime.dispatch_flat("Banking::Customer.Suspend", reference: { value: "c" },
                                                         standing:  { value: "chargeback investigation" })

      expect do
        runtime.dispatch_flat("Banking::CardPayment.Authorize", account: "a1",
                         authorisation: { value: "auth2" }, amount: { cents: 500 },
                         merchant: { value: "Merchant" })
      end.to raise_error(Hecks::Runtime::GivenNotMet, "Authorize refused — customer is active")
    end

    it "leaves a command with no reference-typed attributes at all untouched" do
      runtime = boot_till
      expect { runtime.dispatch_flat("TillRoom::Till.OpenTill", number: { value: "till-1" }) }.not_to raise_error
    end

    # An aliased command-level reference (`reference_to Customer, as: :customer`) hydrates under
    # its raw id argument's name; the dereferenced Hash must win, or `customer.status` digs into
    # the id string and raises TypeError.
    it "resolves an ALIASED command-level reference over its own raw id argument" do
      runtime = funded_account(boot_banking)

      expect do
        runtime.dispatch_flat("Banking::OnboardingCase.Open", customer: "c",
                         reference: { value: "case-1" }, account_number: { value: "a2" })
      end.not_to raise_error

      runtime.dispatch_flat("Banking::Customer.Suspend", reference: { value: "c" },
                                                         standing:  { value: "chargeback investigation" })

      expect do
        runtime.dispatch_flat("Banking::OnboardingCase.Open", customer: "c",
                         reference: { value: "case-2" }, account_number: { value: "a3" })
      end.to raise_error(Hecks::Runtime::GivenNotMet, "Open refused — customer is active")
    end

    # An id that does not resolve must be a clean refusal (here NotFound from
    # `resolve_references`), never a TypeError from digging into a garbage id string.
    it "refuses a dangling aliased reference by name, not with a TypeError from inside the guard" do
      runtime = funded_account(boot_banking)

      expect do
        runtime.dispatch_flat("Banking::OnboardingCase.Open", customer: "no-such-customer",
                         reference: { value: "case-3" }, account_number: { value: "a4" })
      end.to raise_error(Hecks::Runtime::NotFound)
    end

    # An entity command's given/ensures reaching its parent (`parent.status`,
    # `parent.customer.status`); `parent` is structural, so it needs its own hydration path.
    it "resolves an entity command's parent.customer.status, live" do
      runtime = funded_account(boot_banking)
      runtime.dispatch_flat("Banking::Account.Debit", number: { value: "a1" },
                       amount: { cents: 100, currency: "USD" }, narrative: { text: "second" })
      runtime.dispatch_flat("Banking::Account.Debit", number: { value: "a1" },
                       amount: { cents: 100, currency: "USD" }, narrative: { text: "third" })

      expect do
        runtime.dispatch_flat("Banking::Account.LedgerEntry.Reverse",
                              number: { value: "a1" }, sequence: { value: 2 }, narrative: { text: "before" })
      end.not_to raise_error

      runtime.dispatch_flat("Banking::Customer.Suspend", reference: { value: "c" },
                                                         standing:  { value: "chargeback investigation" })

      expect do
        runtime.dispatch_flat("Banking::Account.LedgerEntry.Reverse",
                              number: { value: "a1" }, sequence: { value: 3 }, narrative: { text: "after" })
      end.to raise_error(Hecks::Runtime::GivenNotMet, "Reverse refused — customer is active")
    end

    # `Withdrawal.Dispute`'s "card is not retired" given must read `parent.status`; a bare `status`
    # is nil on Withdrawal, so `nil != "retired"` is always true and never refuses.
    it "resolves an entity command's parent.status — Withdrawal.Dispute on a card that has since been retired" do
      runtime = funded_account(boot_banking)
      runtime.dispatch_flat("Banking::ATMCard.Issue", account: "a1",
                       serial: { value: "s1" }, daily_fee: { amount: 100 })
      runtime.dispatch_flat("Banking::ATMCard.Activate", serial: { value: "s1" })
      runtime.dispatch_flat("Banking::ATMCard.Withdraw", serial: { value: "s1" },
                       cents: { cents: 2000 }, narrative: { text: "Airport cash" })
      runtime.dispatch_flat("Banking::ATMCard.Retire", serial: { value: "s1" })

      expect do
        runtime.dispatch_flat("Banking::ATMCard.Withdrawal.Dispute",
                              serial: { value: "s1" }, sequence: { value: 1 }, narrative: { text: "Not mine" })
      end.to raise_error(Hecks::Runtime::GivenNotMet, "Dispute refused — card is not retired")
    end
  end

  # A sample of the status-guard family on banking.bluebook, one per category: bare customer,
  # bare account, aliased cross-aggregate reference, and an own-record status/state guard.
  describe "the ported customer/account status guards" do
    it "refuses on a bare CUSTOMER status guard — ATMCard.Issue for a suspended customer" do
      runtime = funded_account(boot_banking)
      runtime.dispatch_flat("Banking::Customer.Suspend", reference: { value: "c" },
                                                         standing:  { value: "chargeback investigation" })

      expect do
        runtime.dispatch_flat("Banking::ATMCard.Issue", account: "a1",
                         serial: { value: "s1" }, daily_fee: { amount: 100 })
      end.to raise_error(Hecks::Runtime::GivenNotMet, "Issue refused — customer is active")
    end

    it "refuses on a bare ACCOUNT status guard — CardPayment.Authorize against a frozen account" do
      runtime = funded_account(boot_banking)
      runtime.dispatch_flat("Banking::Account.FreezeAccount", number: { value: "a1" })

      expect do
        runtime.dispatch_flat("Banking::CardPayment.Authorize", account: "a1",
                         authorisation: { value: "auth1" }, amount: { cents: 500 },
                         merchant: { value: "Merchant" })
      end.to raise_error(Hecks::Runtime::GivenNotMet, "Authorize refused — account is open")
    end

    it "refuses on an ALIASED cross-aggregate reference's status guard — Transfer.Request from a frozen source" do
      runtime = funded_account(boot_banking)
      runtime.dispatch_flat("Banking::Account.Open", customer: "c", number: { value: "a2" },
                       kind: { name: "current" }, daily_limit: { cents: 50_000 })
      runtime.dispatch_flat("Banking::Account.FreezeAccount", number: { value: "a1" })

      expect do
        runtime.dispatch_flat("Banking::Transfer.Request", reference: { value: "x1" },
                         source: "a1", destination: "a2", amount: { cents: 100 },
                         narrative: { text: "From a frozen source" })
      end.to raise_error(Hecks::Runtime::GivenNotMet, "Request refused — source account is open")
    end

    it "refuses on an OTHER (own-record) status guard, unrelated to customer/account — " \
       "ATMCard.Retire on an already-retired card" do
      runtime = funded_account(boot_banking)
      runtime.dispatch_flat("Banking::ATMCard.Issue", account: "a1",
                       serial: { value: "s1" }, daily_fee: { amount: 100 })
      runtime.dispatch_flat("Banking::ATMCard.Retire", serial: { value: "s1" })

      # ADR 0025: `Retire` guards on `from: ["issued", "active"]`; the refusal is LifecycleRefused.
      expect do
        runtime.dispatch_flat("Banking::ATMCard.Retire", serial: { value: "s1" })
      end.to raise_error(Hecks::Runtime::LifecycleRefused,
                         'Retire refused — status is "retired", and Retire moves it only from "issued" or "active"')
    end
  end

  describe "the rules have one home" do
    it "leaves each interpreter with one verb" do
      surface = lambda do |klass|
        klass.public_instance_methods(false).sort - [:registry]
      end

      expect(surface[Hecks::Runtime::CommandInterpreter]).to eq([:call])
      expect(surface[Hecks::Runtime::EntityInterpreter]).to  eq([:call])
      # `reference_call` is the query oracle's second entry: the interpreter's own evaluation,
      # skipping the adapter's native hook, so the fuzzer can diff the two answers.
      expect(surface[Hecks::Runtime::QueryInterpreter]).to   eq([:call, :reference_call])
      expect(surface[Hecks::Runtime::PolicyInterpreter]).to  eq([:react])
      expect(surface[Hecks::Runtime::SagaInterpreter]).to    eq([:advance])
    end
  end
end
