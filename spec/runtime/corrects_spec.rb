require "spec_helper"

# `corrects` — CommandBuilder#corrects_impl's own comment gives the full
# reasoning: a command declaring what past event it amends, the
# append-only answer to retroactive correction. spec/dsl_spec.rb covers
# the DSL surface (parsing into the right mutation, build-time
# refusals); this covers the two runtime facts that need a real
# dispatch — the `NothingToCorrect` refusal, and `reverses: true`'s
# structural auto-derivation of the corrective `sets`.
RSpec.describe "a command's corrects" do
  # One inline domain, dispatched through the whole correct/reverse
  # cycle plus the NothingToCorrect refusal — splitting would mean
  # re-declaring the domain per example or threading `registry`/
  # `dispatcher` state across them for no real gain.
  # rubocop:disable-next RSpec/ExampleLength
  it "dispatches a full correct/reverse cycle, refusing correction against a record that was never corrected" do
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      Hecks.bluebook("CorrectsSmoke") do
        vision "Sanity check for the corrects command word."
        core

        aggregate "Box" do
          identified_by :number

          attribute :number,  Number
          attribute :balance, Money, default: { cents: 0 }

          value_object("Number") { attribute :value, String }
          value_object("Money")  { attribute :cents, Integer }

          command "Open" do
            role "Teller"
            attribute :number, Number
            emits "Opened"
          end

          command "Deposit" do
            role "Teller"
            reference_to Box
            attribute :amount, Money
            sets :balance, increment: :amount
            emits "Deposited"
          end

          command "ReverseDeposit" do
            role "Compliance officer"
            reference_to Box

            corrects "Deposited", reason: "duplicate debit, bank error"

            given("the balance covers the reversal") { balance.cents >= 500 }

            sets :balance, decrement: { cents: 500 }
            emits "DepositCorrected"
          end
        end
      end
    end

    dispatcher = Hecks::Runtime::Dispatcher.new(registry)

    dispatcher.dispatch("CorrectsSmoke::Box.Open", number: { value: "b-1" })
    dispatcher.dispatch("CorrectsSmoke::Box.Open", number: { value: "b-2" })
    after_deposit = dispatcher.dispatch("CorrectsSmoke::Box.Deposit", number: { value: "b-1" }, amount: { cents: 1000 })

    expect(after_deposit.instance.balance.cents).to eq(1000)

    expect do
      dispatcher.dispatch("CorrectsSmoke::Box.ReverseDeposit", number: { value: "b-2" })
    end.to raise_error(Hecks::Runtime::NothingToCorrect)

    after_reversal = dispatcher.dispatch("CorrectsSmoke::Box.ReverseDeposit", number: { value: "b-1" })
    expect(after_reversal.instance.balance.cents).to eq(500)
    expect(registry.event_log.map(&:name)).to eq(["Opened", "Opened", "Deposited", "DepositCorrected"])
  end

  # Inline domain declaring reverses: true, dispatched, then reversed —
  # one coherent proof of the structural auto-derivation this example
  # names.
  # rubocop:disable-next RSpec/ExampleLength
  it "auto-derives the inverse mutation for reverses: true" do
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      Hecks.bluebook("CorrectsAutoSmoke") do
        vision "Sanity check for corrects reverses: true structural auto-derivation."
        core

        aggregate "Box" do
          identified_by :number

          attribute :number,  Number
          attribute :balance, Money, default: { cents: 0 }

          value_object("Number") { attribute :value, String }
          value_object("Money")  { attribute :cents, Integer }

          command "Open" do
            role "Teller"
            attribute :number, Number
            emits "Opened"
          end

          command "Deposit" do
            role "Teller"
            reference_to Box
            attribute :amount, Money
            sets :balance, increment: :amount
            emits "Deposited"
          end

          command "ReverseDeposit" do
            role "Compliance officer"
            reference_to Box
            attribute :amount, Money
            corrects "Deposited", reason: "duplicate debit, bank error", reverses: true
            emits "DepositCorrected"
          end
        end
      end
    end

    dispatcher = Hecks::Runtime::Dispatcher.new(registry)
    dispatcher.dispatch("CorrectsAutoSmoke::Box.Open", number: { value: "b-1" })
    dispatcher.dispatch("CorrectsAutoSmoke::Box.Deposit", number: { value: "b-1" }, amount: { cents: 1000 })

    reversed = dispatcher.dispatch("CorrectsAutoSmoke::Box.ReverseDeposit", number: { value: "b-1" }, amount: { cents: 1000 })
    expect(reversed.instance.balance.cents).to eq(0)
  end

  # Inline domain binding the as: name and reading it back from both
  # given and ensures — one dispatch proving the whole binding, not
  # separable without re-declaring the domain.
  # rubocop:disable-next RSpec/ExampleLength
  it "binds corrects' own as: name to the located event's payload, readable from given and ensures" do
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      Hecks.bluebook("CorrectsAsSmoke") do
        vision "corrects' own as: binds the located event for given/ensures to read."
        core

        aggregate "Box" do
          identified_by :number

          attribute :number,  Number
          attribute :balance, Money, default: { cents: 0 }

          value_object("Number") { attribute :value, String }
          value_object("Money")  { attribute :cents, Integer }

          command "Open" do
            role "Teller"
            attribute :number, Number
            emits "Opened"
          end

          command "Deposit" do
            role "Teller"
            reference_to Box
            attribute :amount, Money
            sets :balance, increment: :amount
            emits "Deposited"
          end

          # `as: :original` binds the LOCATED "Deposited" event's own
          # payload — checked from BOTH sides: a `given` (pre-mutation)
          # refusing a reversal that doesn't name the exact amount
          # originally deposited, and an `ensures` (post-mutation)
          # confirming the balance actually landed back where it
          # started, both reading `original.amount.cents`.
          command "ReverseDeposit" do
            role "Compliance officer"
            reference_to Box
            attribute :amount, Money

            corrects "Deposited", as: :original, reason: "duplicate debit, bank error"

            given("the reversal names the exact amount originally deposited") { amount.cents == original.amount.cents }
            ensures("the balance no longer reflects the original deposit") { balance.cents != old.balance.cents }
            ensures("the amount corrected still names the exact original event") { original.amount.cents == amount.cents }

            sets :balance, decrement: :amount
            emits "DepositCorrected"
          end
        end
      end
    end

    dispatcher = Hecks::Runtime::Dispatcher.new(registry)

    dispatcher.dispatch("CorrectsAsSmoke::Box.Open", number: { value: "b-1" })
    dispatcher.dispatch("CorrectsAsSmoke::Box.Deposit", number: { value: "b-1" }, amount: { cents: 1000 })

    expect do
      dispatcher.dispatch("CorrectsAsSmoke::Box.ReverseDeposit", number: { value: "b-1" }, amount: { cents: 999 })
    end.to raise_error(Hecks::Runtime::GivenNotMet)

    reversed = dispatcher.dispatch("CorrectsAsSmoke::Box.ReverseDeposit", number: { value: "b-1" }, amount: { cents: 1000 })
    expect(reversed.instance.balance.cents).to eq(0)
  end

  # BUG#30 — `corrects` DECLARED ON AN ENTITY-LEVEL COMMAND, not the
  # aggregate. Before this fix, `Ledger::Entry.Amend` (below) crashed
  # outright with `Hecks::Runtime::WiringError` — `EntityInterpreter`
  # never called `enforce_correction_target` at all, and
  # `EntityElement.apply_to_element`'s own `case mutation.op` had no
  # `:corrects` branch. `qa/stress_domains/corrections` found this live
  # (ANGLE-9); this is the runtime regression coverage for the fix.
  #
  # `Ledger.Record` — AGGREGATE-level — is what actually `emits
  # "EntryRecorded"`; `Entry.Amend` — ENTITY-level — is what `corrects`
  # it. This is deliberate, not incidental: an entity has no event
  # stream of its own, so admissibility is checked against the PARENT
  # record's own history (see `EntityInterpreter#step_enforce_givens`'s
  # own comment for the full reasoning) — proving the fix against a
  # correction target that an AGGREGATE-level sibling command emits is
  # the realistic shape, not a simplification for the test's own sake.
  #
  # `Ledger.Import` — a SECOND way to add an Entry that never emits
  # "EntryRecorded" at all — exists purely so the refusal half below has
  # a real, already-existing entity element to address whose PARENT
  # ledger's own event history genuinely never announced the corrected
  # event, the entity-level analogue of the aggregate-level "two boxes,
  # only one deposited" refusal proof above. TWO SEPARATE LEDGERS, for
  # the same reason the aggregate-level proof uses two separate boxes:
  # admissibility is checked against the PARENT RECORD's own history as
  # a whole (this file's own `step_enforce_givens` comment), so a second
  # entry added to the SAME already-recording ledger would still find
  # "EntryRecorded" in that ledger's history and dispatch cleanly — the
  # refusal needs a ledger whose own history genuinely never has it.
  # rubocop:disable-next RSpec/ExampleLength
  it "dispatches an entity-level corrects command, binding as: and reading it from given/ensures, " \
     "refusing cleanly (not crashing) against an entry whose ledger never recorded it" do
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      Hecks.bluebook("EntityCorrectsSmoke") do
        vision "Sanity check for corrects declared on an entity-level command."
        core

        aggregate "Ledger" do
          identified_by :reference

          attribute :reference, Reference
          attribute :entries,   list_of(Entry)

          value_object("Reference")     { attribute :value, String }
          value_object("Amount")        { attribute :cents, Integer }
          value_object("EntrySequence") { attribute :value, Integer }

          command "Open" do
            role "Clerk"
            attribute :reference, Reference
            emits "Opened"
          end

          command "Record" do
            role "Clerk"
            reference_to Ledger
            attribute :amount, Amount
            sets :entries, append: { amount: :amount }
            emits "EntryRecorded"
          end

          # NEVER emits "EntryRecorded" — the clean-refusal fixture's
          # own entry gets here instead.
          command "Import" do
            role "Clerk"
            reference_to Ledger
            attribute :amount, Amount
            sets :entries, append: { amount: :amount }
            emits "EntryImported"
          end

          entity "Entry" do
            identified_by :sequence

            attribute :sequence, EntrySequence
            attribute :amount,   Amount

            # `as: :original` bound and read from both given and
            # ensures, the entity-level twin of the aggregate-level
            # `as:` example above.
            command "Amend" do
              role "Auditor"
              attribute :amount, Amount

              corrects "EntryRecorded", as: :original, reason: "an entry amount was mis-keyed"

              given("the amendment names a different amount than originally recorded") do
                amount.cents != original.amount.cents
              end
              ensures("the amount changed") { amount.cents != old.amount.cents }
              # Proves `original` (the `as:`-bound corrected event's own
              # payload) is readable from ensures too, not just given —
              # the same predicate as the given above, re-checked
              # post-mutation against the settled record.
              ensures("the settled amount still differs from the original event it corrects") do
                amount.cents != original.amount.cents
              end

              sets :amount
              emits "EntryAmended"
            end
          end
        end
      end
    end

    dispatcher = Hecks::Runtime::Dispatcher.new(registry)

    dispatcher.dispatch("EntityCorrectsSmoke::Ledger.Open", reference: { value: "l-1" })
    dispatcher.dispatch("EntityCorrectsSmoke::Ledger.Record", reference: { value: "l-1" }, amount: { cents: 1000 })

    dispatcher.dispatch("EntityCorrectsSmoke::Ledger.Open", reference: { value: "l-2" })
    dispatcher.dispatch("EntityCorrectsSmoke::Ledger.Import", reference: { value: "l-2" }, amount: { cents: 2000 })

    # LEGITIMATE — l-1's own entry (sequence 1) targets a real,
    # already-emitted "EntryRecorded" for THIS exact ledger. Dispatches
    # cleanly, never a WiringError.
    amended = dispatcher.dispatch("EntityCorrectsSmoke::Ledger.Entry.Amend",
                                  reference: { value: "l-1" }, sequence: { value: 1 }, amount: { cents: 1500 })
    entry = amended.instance.entries.find { |e| e[:sequence].value == 1 }
    expect(entry[:amount].cents).to eq(1500)

    # ILLEGITIMATE — l-2's own entry exists for real (imported, not
    # recorded), but l-2's own event history never emitted
    # "EntryRecorded" at all — refuses with NothingToCorrect, never a
    # crash.
    expect do
      dispatcher.dispatch("EntityCorrectsSmoke::Ledger.Entry.Amend",
                          reference: { value: "l-2" }, sequence: { value: 1 }, amount: { cents: 500 })
    end.to raise_error(Hecks::Runtime::NothingToCorrect)

    expect(registry.event_log.map(&:name)).to eq(%w[Opened EntryRecorded Opened EntryImported EntryAmended])
  end

  # A build-time refusal proof — the whole point is the raise, and the
  # inline domain is what makes the lossy op concrete.
  # rubocop:disable-next RSpec/ExampleLength
  it "refuses reverses: true at build time when the original used a lossy op" do
    expect do
      Hecks.bluebook("CorrectsLossySmoke") do
        vision "reverses: true must refuse against a lossy original op."
        core

        aggregate "Box" do
          identified_by :number
          attribute :number,  Number
          attribute :balance, Money, default: { cents: 0 }

          value_object("Number") { attribute :value, String }
          value_object("Money")  { attribute :cents, Integer }

          command "Open" do
            role "Teller"
            attribute :number, Number
            emits "Opened"
          end

          command "Overwrite" do
            role "Teller"
            reference_to Box
            attribute :amount, Money
            sets :balance, to: :amount
            emits "Overwritten"
          end

          command "ReverseOverwrite" do
            role "Compliance officer"
            reference_to Box
            corrects "Overwritten", reason: "wrong amount", reverses: true
            emits "OverwriteCorrected"
          end
        end
      end
    end.to raise_error(Hecks::Bluebook::DSL::Malformed, /not statically invertible/)
  end
end
