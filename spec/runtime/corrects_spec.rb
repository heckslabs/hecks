require "spec_helper"

# `corrects` runtime facts that need a real dispatch: the `NothingToCorrect` refusal and
# `reverses: true` auto-deriving the corrective `sets` (DSL parsing is in spec/dsl_spec.rb).
RSpec.describe "a command's corrects" do
  # One inline domain covers the correct/reverse cycle and the refusal; splitting would repeat it.
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

    dispatcher.dispatch_flat("CorrectsSmoke::Box.Open", number: { value: "b-1" })
    dispatcher.dispatch_flat("CorrectsSmoke::Box.Open", number: { value: "b-2" })
    after_deposit = dispatcher.dispatch_flat("CorrectsSmoke::Box.Deposit", number: { value: "b-1" }, amount: { cents: 1000 })

    expect(after_deposit.instance.balance.cents).to eq(1000)

    expect do
      dispatcher.dispatch_flat("CorrectsSmoke::Box.ReverseDeposit", number: { value: "b-2" })
    end.to raise_error(Hecks::Runtime::NothingToCorrect)

    after_reversal = dispatcher.dispatch_flat("CorrectsSmoke::Box.ReverseDeposit", number: { value: "b-1" })
    expect(after_reversal.instance.balance.cents).to eq(500)
    expect(registry.event_log.map(&:name)).to eq(["Opened", "Opened", "Deposited", "DepositCorrected"])
  end

  # Inline domain with reverses: true, dispatched then reversed.
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
    dispatcher.dispatch_flat("CorrectsAutoSmoke::Box.Open", number: { value: "b-1" })
    dispatcher.dispatch_flat("CorrectsAutoSmoke::Box.Deposit", number: { value: "b-1" }, amount: { cents: 1000 })

    reversed = dispatcher.dispatch_flat("CorrectsAutoSmoke::Box.ReverseDeposit", number: { value: "b-1" },
                                                                                 amount: { cents: 1000 })
    expect(reversed.instance.balance.cents).to eq(0)
  end

  # Binds the as: name and reads it from both given and ensures in one dispatch.
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

          # `as: :original` binds the located "Deposited" payload; a `given` (refuses a wrong
          # amount) and an `ensures` (balance restored) read `original.amount.cents`.
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

    dispatcher.dispatch_flat("CorrectsAsSmoke::Box.Open", number: { value: "b-1" })
    dispatcher.dispatch_flat("CorrectsAsSmoke::Box.Deposit", number: { value: "b-1" }, amount: { cents: 1000 })

    expect do
      dispatcher.dispatch_flat("CorrectsAsSmoke::Box.ReverseDeposit", number: { value: "b-1" }, amount: { cents: 999 })
    end.to raise_error(Hecks::Runtime::GivenNotMet)

    reversed = dispatcher.dispatch_flat("CorrectsAsSmoke::Box.ReverseDeposit", number: { value: "b-1" }, amount: { cents: 1000 })
    expect(reversed.instance.balance.cents).to eq(0)
  end

  # `corrects` on an entity-level command must not crash with WiringError. `Ledger.Record`
  # (aggregate) emits "EntryRecorded"; `Entry.Amend` (entity) corrects it, because an entity has
  # no event stream and admissibility is checked against the parent record's history.
  # `Ledger.Import` adds an Entry without emitting it, so the refusal case uses a separate ledger
  # whose history never announced the event.
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

          # Never emits "EntryRecorded"; the refusal fixture's entry arrives here.
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

            # `as: :original` is bound and read from given and ensures, as in the aggregate one.
            command "Amend" do
              role "Auditor"
              attribute :amount, Amount

              corrects "EntryRecorded", as: :original, reason: "an entry amount was mis-keyed"

              given("the amendment names a different amount than originally recorded") do
                amount.cents != original.amount.cents
              end
              ensures("the amount changed") { amount.cents != old.amount.cents }
              # `original` is readable from ensures too, not just given.
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

    dispatcher.dispatch_flat("EntityCorrectsSmoke::Ledger.Open", reference: { value: "l-1" })
    dispatcher.dispatch_flat("EntityCorrectsSmoke::Ledger.Record", reference: { value: "l-1" }, amount: { cents: 1000 })

    dispatcher.dispatch_flat("EntityCorrectsSmoke::Ledger.Open", reference: { value: "l-2" })
    dispatcher.dispatch_flat("EntityCorrectsSmoke::Ledger.Import", reference: { value: "l-2" }, amount: { cents: 2000 })

    # Legitimate: l-1's entry targets an already-emitted "EntryRecorded"; dispatches cleanly.
    amended = dispatcher.dispatch_flat("EntityCorrectsSmoke::Ledger.Entry.Amend",
                                       reference: { value: "l-1" }, sequence: { value: 1 }, amount: { cents: 1500 })
    entry = amended.instance.entries.find { |e| e[:sequence].value == 1 }
    expect(entry[:amount].cents).to eq(1500)

    # Illegitimate: l-2's history never emitted "EntryRecorded"; refuses with NothingToCorrect.
    expect do
      dispatcher.dispatch_flat("EntityCorrectsSmoke::Ledger.Entry.Amend",
                               reference: { value: "l-2" }, sequence: { value: 1 }, amount: { cents: 500 })
    end.to raise_error(Hecks::Runtime::NothingToCorrect)

    expect(registry.event_log.map(&:name)).to eq(%w[Opened EntryRecorded Opened EntryImported EntryAmended])
  end

  # Build-time refusal: the raise is the point; the inline domain makes the lossy op concrete.
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
