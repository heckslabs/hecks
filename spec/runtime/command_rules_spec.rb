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
    runtime.dispatch("Banking::Customer.Register", reference: { value: "c" },
                     name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
    runtime.dispatch("Banking::Account.Open", customer: "c", number: { value: "a1" },
                                              kind: { name: "current" }, daily_limit: { cents: 50_000 })
    runtime.dispatch("Banking::Account.Credit", number: { value: "a1" }, amount: { cents: 10_000, currency: "USD" },
narrative: { text: "Opening" })
    runtime
  end

  def narrative = { text: "Corrected" }

  describe "Integer-or-nothing arithmetic" do
    # `till.bluebook`'s Money is a SINGLE-field value object (`cents` alone),
    # so a bare scalar amount is exactly the unambiguous case
    # `Value::Coercion#fields_for` deliberately widened to auto-wrap
    # (migration plan task 5, this split's own item 17) — the same
    # precedent `#from_identifier` already set. It no longer refuses at the
    # "give me an object, not a scalar" gate; it auto-wraps to
    # `{ cents: "a lot" }` and refuses one step later, at
    # `check_numeric_fields`, with a message that names the actual
    # field and type rather than a generic shape complaint.
    it "refuses a non-Integer amount on a RECORD, in so many words" do
      runtime = boot_till
      runtime.dispatch("TillRoom::Till.OpenTill", number: { value: "till-1" })

      expect do
        runtime.dispatch("TillRoom::Till.TakeIn", number: { value: "till-1" }, amount: "a lot")
      end.to raise_error(Hecks::Runtime::TypeMismatch, 'Money.cents expects Integer, got "a lot"')
    end

    it "refuses a non-Integer amount on an ELEMENT, in the same words" do
      runtime = funded_account(boot_banking)

      expect do
        runtime.dispatch("Banking::Account.LedgerEntry.Amend",
                         number: { value: "a1" }, sequence: { value: 1 }, adjustment: { cents: "a lot", currency: "USD" }, narrative: narrative)
      end.to raise_error(Hecks::Runtime::TypeMismatch,
                         'Money.cents expects Integer, got "a lot"')
    end

    # AN ABSENT ARGUMENT IS NIL, NOT ITS OWN NAME.
    #
    # `resolve_source` used to fall through to the Symbol when the argument was
    # missing, so an absent `amount` arrived at coercion AS `:amount` and was
    # refused with "amount is a Money — pass its fields as an object, not
    # :amount" — which describes passing the wrong SHAPE, a mistake the caller
    # had not made. That sentence became load-bearing downstream before anyone
    # noticed it was wrong. It is gone : the message now names what is
    # actually wrong, worded through Rendering.describe, which spells nil "nil".
    it "says an absent OPTIONAL argument is nil, not the name of the argument" do
      runtime = boot_till
      runtime.dispatch("TillRoom::Till.OpenTill", number: { value: "till-1" })

      # `note` is optional, so the payload gate lets this through and the
      # mutation actually resolves an argument that is not there — the only
      # remaining path to the leak. It used to resolve to the SYMBOL `:note`
      # and refuse with "note is a Note — pass its fields as an object, not
      # :note", describing a mistake the caller had not made.
      state = runtime.dispatch("TillRoom::Till.TakeIn",
                               number: { value: "till-1" }, amount: { cents: 300 }).state

      expect(state[:note]).to be_nil
      expect(state[:balance].to_h).to eq(cents: 300)
    end

    it "refuses an absent REQUIRED argument at the gate, before any rule runs" do
      runtime = funded_account(boot_banking)

      expect do
        runtime.dispatch("Banking::Account.Credit",
                         number: { value: "a1" }, narrative: { text: "No amount at all" })
      end.to raise_error(Hecks::Runtime::AbsentArgument,
                         "Credit was not given amount — it takes amount, narrative")
    end

    # The counterpart on the OTHER side of the arithmetic : a total that has
    # never been set reads as zero (`current ||= 0`), and only the total does.
    # Conflating the two — mapping every absent value to 0 —
    # once let an absent amount increment by zero and silently SUCCEED
    # where a refusal was owed. The distinction is the whole point : an unset
    # TOTAL is zero ; an absent AMOUNT is a caller's mistake.
    it "still starts an unset total at zero" do
      runtime = funded_account(boot_banking)
      state   = runtime.dispatch("Banking::Account.ApplyFee",
                                 number: { value: "a1" }, amount: { cents: 250, currency: "USD" },
                                 narrative: narrative)
                       .state

      expect(state[:fees_cents].to_h).to eq(cents: 250, currency: "USD")
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
      end.to raise_error(Hecks::Runtime::GivenNotMet,
                         "Amend refused — an amendment leaves a non-negative amount")
    end

    it "carries the failing comparison's own operands as #detail, off #message" do
      runtime = funded_account(boot_banking)

      error = nil
      begin
        runtime.dispatch("Banking::Account.LedgerEntry.Amend",
                         number: { value: "a1" }, sequence: { value: 1 }, adjustment: { cents: -10_001, currency: "USD" }, narrative: narrative)
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
      runtime.dispatch("Banking::Account.FreezeAccount", number: { value: "a1" }, id: "a1")

      # Freeze used to carry its own explicit `given("account is open")`
      # for this; S10 (ADR 0025) replaced it with a real lifecycle guard
      # (`command "FreezeAccount", from: "open"`), checked in the SAME
      # dispatch step `enforce_givens` already runs (`Admissibility#
      # enforce_lifecycle_guard`, folded in right after a command's own
      # givens) — an already-frozen account is refused there, by name,
      # naming the ACTUAL reason (the state it's in and the one state it
      # runs from) rather than a free-text sentence that could drift out
      # of sync with the state machine and did.
      expect do
        runtime.dispatch("Banking::Account.FreezeAccount", number: { value: "a1" }, id: "a1")
      end.to raise_error(Hecks::Runtime::LifecycleRefused,
                         'FreezeAccount refused — status is "frozen", and FreezeAccount moves it only from "open"')
    end

    it "refuses a move an ENTITY's own machine does not admit, in the same shape" do
      runtime = funded_account(boot_banking)
      runtime.dispatch("Banking::Account.LedgerEntry.Reverse",
                       number: { value: "a1" }, sequence: { value: 1 }, narrative: narrative)

      # Same overlap as Account.FreezeAccount above: Amend now carries its own
      # `given("entry is posted")`, which pre-empts the entity's own
      # lifecycle machine (`admissible_transition` runs after
      # `enforce_givens`) — GivenNotMet, not LifecycleRefused. Still
      # refused, same as before this guard existed.
      expect do
        runtime.dispatch("Banking::Account.LedgerEntry.Amend",
                         number: { value: "a1" }, sequence: { value: 1 }, adjustment: { cents: 100, currency: "USD" }, narrative: narrative)
      end.to raise_error(Hecks::Runtime::GivenNotMet, "Amend refused — entry is posted")
    end

    it "does not settle a transfer until its destination credit is recorded" do
      runtime = boot_banking
      runtime.dispatch("Banking::Customer.Register", reference: { value: "c-src" },
                       name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
      runtime.dispatch("Banking::Account.Open", number: { value: "src" }, customer: "c-src",
                       kind: { name: "current" }, daily_limit: { cents: 50_000 })
      runtime.dispatch("Banking::Customer.Register", reference: { value: "c-dst" },
                       name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
      runtime.dispatch("Banking::Account.Open", number: { value: "dst" }, customer: "c-dst",
                       kind: { name: "current" }, daily_limit: { cents: 50_000 })
      runtime.dispatch("Banking::Transfer.Request",
                       reference: { value: "x1" }, source: "src", destination: "dst",
                       amount: { cents: 100 }, narrative: { text: "A transfer waiting for credit" })
      runtime.dispatch("Banking::Transfer.Debited", transfer: "x1")

      # S10, ADR 0025 — Settle's own `given("transfer is credited")` moved
      # to `from: "credited"` on the command itself; the refusal is
      # LifecycleRefused now, same shape as Account.FreezeAccount above.
      # Still refused before any destination credit was recorded, same
      # guarantee as before.
      expect do
        runtime.dispatch("Banking::Transfer.Settle", transfer: "x1")
      end.to raise_error(Hecks::Runtime::LifecycleRefused,
                         'Settle refused — status is "debited", and Settle moves it only from "credited"')
    end

    it "refuses duplicate and out-of-order transfer legs without changing their state" do
      runtime = boot_banking
      runtime.dispatch("Banking::Customer.Register", reference: { value: "c-src" },
                       name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
      runtime.dispatch("Banking::Account.Open", number: { value: "src" }, customer: "c-src",
                       kind: { name: "current" }, daily_limit: { cents: 50_000 })
      runtime.dispatch("Banking::Customer.Register", reference: { value: "c-dst" },
                       name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
      runtime.dispatch("Banking::Account.Open", number: { value: "dst" }, customer: "c-dst",
                       kind: { name: "current" }, daily_limit: { cents: 50_000 })
      runtime.dispatch("Banking::Transfer.Request",
                       reference: { value: "x1" }, source: "src", destination: "dst",
                       amount: { cents: 100 }, narrative: { text: "An ordered transfer" })

      # S10, ADR 0025 — Settle/Credited's own status guards moved to
      # `from:` on each command; both refusals are LifecycleRefused now.
      # Still refused at every one of these out-of-order points, same
      # guarantee as before.
      expect { runtime.dispatch("Banking::Transfer.Settle", transfer: "x1") }
        .to raise_error(Hecks::Runtime::LifecycleRefused,
                        'Settle refused — status is "requested", and Settle moves it only from "credited"')

      runtime.dispatch("Banking::Transfer.Debited", transfer: "x1")
      runtime.dispatch("Banking::Transfer.Credited", transfer: "x1")

      expect { runtime.dispatch("Banking::Transfer.Credited", transfer: "x1") }
        .to raise_error(Hecks::Runtime::LifecycleRefused,
                        'Credited refused — status is "credited", and Credited moves it only from "debited"')
      expect(runtime.registry.repository("Banking", runtime.registry.bluebook("Banking").aggregate("Transfer"))
                    .find("x1")[:status]).to eq("credited")
    end
  end

  # A `given`/`ensures` reading a RELATED record's own field —
  # `customer.status`, not just the dispatching record's own attributes.
  # The pure expression evaluator never gained repository access for
  # this: CommandRules::References#dereference resolves it BEFORE
  # evaluation, once, into a plain Hash `Resolver#lookup` digs into
  # exactly as it always has. Covers both shapes that reach it —
  # an aggregate's OWN declared reference (Account's `reference_to
  # Customer`, read off the record's stored state) and a COMMAND's own
  # reference-typed argument (CardPayment.Authorize's `reference_to
  # Account`, read off the dispatch payload) — plus the two-hop chain
  # that composes them.
  describe "dereferencing a related record's field in given/ensures" do
    it "reads a stored aggregate-level reference's field, live — not a snapshot taken at dispatch time" do
      runtime = funded_account(boot_banking)

      expect do
        runtime.dispatch("Banking::Account.Credit", number: { value: "a1" },
                         amount: { cents: 100, currency: "USD" }, narrative: { text: "before" })
      end.not_to raise_error

      runtime.dispatch("Banking::Customer.Suspend", reference: { value: "c" },
                                                    standing:  { value: "chargeback investigation" })

      expect do
        runtime.dispatch("Banking::Account.Credit", number: { value: "a1" },
                         amount: { cents: 100, currency: "USD" }, narrative: { text: "after" })
      end.to raise_error(Hecks::Runtime::GivenNotMet, "Credit refused — customer is active")
    end

    it "reads a command-level reference argument's field (one hop)" do
      runtime = funded_account(boot_banking)

      expect do
        runtime.dispatch("Banking::ATMCard.Issue", account: "a1",
                         serial: { value: "s1" }, daily_fee: { cents: 100 })
      end.not_to raise_error
    end

    it "chains through a command-level reference into ITS OWN aggregate-level reference (two hops)" do
      runtime = funded_account(boot_banking)

      expect do
        runtime.dispatch("Banking::CardPayment.Authorize", account: "a1",
                         authorisation: { value: "auth1" }, amount: { cents: 500, currency: "USD" },
                         merchant: { value: "Merchant" })
      end.not_to raise_error

      runtime.dispatch("Banking::Customer.Suspend", reference: { value: "c" },
                                                    standing:  { value: "chargeback investigation" })

      expect do
        runtime.dispatch("Banking::CardPayment.Authorize", account: "a1",
                         authorisation: { value: "auth2" }, amount: { cents: 500, currency: "USD" },
                         merchant: { value: "Merchant" })
      end.to raise_error(Hecks::Runtime::GivenNotMet, "Authorize refused — customer is active")
    end

    it "leaves a command with no reference-typed attributes at all untouched" do
      runtime = boot_till
      expect { runtime.dispatch("TillRoom::Till.OpenTill", number: { value: "till-1" }) }.not_to raise_error
    end

    # Found by the fuzzer, not by hand: an ALIASED command-level reference
    # (`reference_to Customer, as: :customer`) hydrates under the SAME name
    # its raw id argument already holds — unlike an unaliased one
    # (`account_id` the argument, `account` the hydrated key, no
    # collision). The dereferenced Hash must win that collision, or
    # `customer.status` digs into the raw id string instead — a TypeError,
    # not a refusal, the moment the id doesn't resolve to a real record.
    it "resolves an ALIASED command-level reference over its own raw id argument" do
      runtime = funded_account(boot_banking)

      expect do
        runtime.dispatch("Banking::OnboardingCase.Open", customer: "c",
                         reference: { value: "case-1" }, account_number: { value: "a2" })
      end.not_to raise_error

      runtime.dispatch("Banking::Customer.Suspend", reference: { value: "c" },
                                                    standing:  { value: "chargeback investigation" })

      expect do
        runtime.dispatch("Banking::OnboardingCase.Open", customer: "c",
                         reference: { value: "case-2" }, account_number: { value: "a3" })
      end.to raise_error(Hecks::Runtime::GivenNotMet, "Open refused — customer is active")
    end

    # The other half of the same bug: an id that does NOT resolve to a real
    # record must be a clean refusal (whatever the aggregate's own gates
    # say — here NotFound, from a plain `reference_to Customer, as:
    # :customer` failing existence at resolve_references, BEFORE givens
    # ever run) — never the dereferencer's problem to raise a TypeError
    # over. This is what the fuzzer actually found: a garbage id string
    # reaching `customer.status` and blowing up on `String#[]`.
    it "refuses a dangling aliased reference by name, not with a TypeError from inside the guard" do
      runtime = funded_account(boot_banking)

      expect do
        runtime.dispatch("Banking::OnboardingCase.Open", customer: "no-such-customer",
                         reference: { value: "case-3" }, account_number: { value: "a4" })
      end.to raise_error(Hecks::Runtime::NotFound)
    end

    # An ENTITY command's given/ensures reaching its own PARENT aggregate
    # (`parent.status`) and, through it, the parent's OWN reference
    # (`parent.customer.status`) — a third shape none of the above cover:
    # `parent` names a structural relationship (EntityInterpreter's own
    # `ctx.instance`), not a declared reference attribute, so it needs its
    # own hydration path rather than reusing `dereference`'s attribute
    # scan directly.
    it "resolves an entity command's parent.customer.status, live" do
      runtime = funded_account(boot_banking)
      runtime.dispatch("Banking::Account.Debit", number: { value: "a1" },
                       amount: { cents: 100, currency: "USD" }, narrative: { text: "second" })
      runtime.dispatch("Banking::Account.Debit", number: { value: "a1" },
                       amount: { cents: 100, currency: "USD" }, narrative: { text: "third" })

      expect do
        runtime.dispatch("Banking::Account.LedgerEntry.Reverse",
                         number: { value: "a1" }, sequence: { value: 2 }, narrative: { text: "before" })
      end.not_to raise_error

      runtime.dispatch("Banking::Customer.Suspend", reference: { value: "c" },
                                                    standing:  { value: "chargeback investigation" })

      expect do
        runtime.dispatch("Banking::Account.LedgerEntry.Reverse",
                         number: { value: "a1" }, sequence: { value: 3 }, narrative: { text: "after" })
      end.to raise_error(Hecks::Runtime::GivenNotMet, "Reverse refused — customer is active")
    end

    # Wave 8's own dependency-planning audit surfaced this as a real, live
    # bug, not a hypothetical one: `Withdrawal.Dispute`'s own "card is not
    # retired" given used to read a bare `status` — a field Withdrawal
    # itself has no `:status` attribute for (its own lifecycle field is
    # `:state`) — so it always compared `nil != "retired"`, always true,
    # and never actually refused anything regardless of the card's real
    # state. Fixed to `parent.status`, the ATMCard's own lifecycle field —
    # this proves the fix live, not just that the static analyzer's own
    # unresolved_dependencies cleared.
    it "resolves an entity command's parent.status — Withdrawal.Dispute on a card that has since been retired" do
      runtime = funded_account(boot_banking)
      runtime.dispatch("Banking::ATMCard.Issue", account: "a1",
                       serial: { value: "s1" }, daily_fee: { cents: 100 })
      runtime.dispatch("Banking::ATMCard.Activate", serial: { value: "s1" })
      runtime.dispatch("Banking::ATMCard.Withdraw", serial: { value: "s1" },
                       cents: { cents: 2000 }, narrative: { text: "Airport cash" })
      runtime.dispatch("Banking::ATMCard.Retire", serial: { value: "s1" })

      expect do
        runtime.dispatch("Banking::ATMCard.Withdrawal.Dispute",
                         serial: { value: "s1" }, sequence: { value: 1 }, narrative: { text: "Not mine" })
      end.to raise_error(Hecks::Runtime::GivenNotMet, "Dispute refused — card is not retired")
    end
  end

  # A REPRESENTATIVE SAMPLE of the customer/account-status guard family
  # ported onto banking.bluebook (feat/banking-status-guards) — not
  # exhaustive (~113 individual `given`s across ~56 commands), but one
  # real example per category: a bare CUSTOMER-status guard, a bare
  # ACCOUNT-status guard, an aliased cross-aggregate reference
  # (source/destination) status guard, and an "other" own-record
  # status/state guard that has nothing to do with customer/account at
  # all. Section 223's "dereferencing a related record's field" tests,
  # above, already prove several more of these guards fire as a side
  # effect of proving the DEREFERENCING mechanism itself — this section
  # is about the GUARDS, not the mechanism.
  describe "the ported customer/account status guards" do
    it "refuses on a bare CUSTOMER status guard — ATMCard.Issue for a suspended customer" do
      runtime = funded_account(boot_banking)
      runtime.dispatch("Banking::Customer.Suspend", reference: { value: "c" },
                                                    standing:  { value: "chargeback investigation" })

      expect do
        runtime.dispatch("Banking::ATMCard.Issue", account: "a1",
                         serial: { value: "s1" }, daily_fee: { cents: 100 })
      end.to raise_error(Hecks::Runtime::GivenNotMet, "Issue refused — customer is active")
    end

    it "refuses on a bare ACCOUNT status guard — CardPayment.Authorize against a frozen account" do
      runtime = funded_account(boot_banking)
      runtime.dispatch("Banking::Account.FreezeAccount", number: { value: "a1" })

      expect do
        runtime.dispatch("Banking::CardPayment.Authorize", account: "a1",
                         authorisation: { value: "auth1" }, amount: { cents: 500, currency: "USD" },
                         merchant: { value: "Merchant" })
      end.to raise_error(Hecks::Runtime::GivenNotMet, "Authorize refused — account is open")
    end

    it "refuses on an ALIASED cross-aggregate reference's status guard — Transfer.Request from a frozen source" do
      runtime = funded_account(boot_banking)
      runtime.dispatch("Banking::Account.Open", customer: "c", number: { value: "a2" },
                       kind: { name: "current" }, daily_limit: { cents: 50_000 })
      runtime.dispatch("Banking::Account.FreezeAccount", number: { value: "a1" })

      expect do
        runtime.dispatch("Banking::Transfer.Request", reference: { value: "x1" },
                         source: "a1", destination: "a2", amount: { cents: 100 },
                         narrative: { text: "From a frozen source" })
      end.to raise_error(Hecks::Runtime::GivenNotMet, "Request refused — source account is open")
    end

    it "refuses on an OTHER (own-record) status guard, unrelated to customer/account — ATMCard.Retire on an already-retired card" do
      runtime = funded_account(boot_banking)
      runtime.dispatch("Banking::ATMCard.Issue", account: "a1",
                       serial: { value: "s1" }, daily_fee: { cents: 100 })
      runtime.dispatch("Banking::ATMCard.Retire", serial: { value: "s1" })

      # S10, ADR 0025 — `Retire`'s own guard moved from a free-text given
      # ("card is issued or active") to `from: ["issued", "active"]` on
      # the command itself, redundant-but-kept alongside the matching
      # `transition` — the refusal is now LifecycleRefused, naming the
      # actual state machine, not a hand-typed GivenNotMet string.
      expect do
        runtime.dispatch("Banking::ATMCard.Retire", serial: { value: "s1" })
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
      # `reference_call` is the query oracle's second DOOR into the same
      # home — the interpreter's own evaluation, skipping the adapter's
      # native hook, so the fuzzer can diff the two answers. Same
      # declared-query resolution, same argument gate, same interpret —
      # a second entrance, not a second set of rules.
      expect(surface[Hecks::Runtime::QueryInterpreter]).to   eq([:call, :reference_call])
      expect(surface[Hecks::Runtime::PolicyInterpreter]).to  eq([:react])
      expect(surface[Hecks::Runtime::SagaInterpreter]).to    eq([:advance])
    end
  end
end
