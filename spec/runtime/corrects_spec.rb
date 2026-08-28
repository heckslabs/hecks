require "spec_helper"

# `corrects` — CommandBuilder#corrects_impl's own comment gives the full
# reasoning: a command declaring what past event it amends, the
# append-only answer to retroactive correction. spec/dsl_spec.rb covers
# the DSL surface (parsing into the right mutation, build-time
# refusals); this covers the two runtime facts that need a real
# dispatch — the `NothingToCorrect` refusal, and `reverses: true`'s
# structural auto-derivation of the corrective `sets`.
RSpec.describe "a command's corrects" do
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

    expect {
      dispatcher.dispatch("CorrectsSmoke::Box.ReverseDeposit", number: { value: "b-2" })
    }.to raise_error(Hecks::Runtime::NothingToCorrect)

    after_reversal = dispatcher.dispatch("CorrectsSmoke::Box.ReverseDeposit", number: { value: "b-1" })
    expect(after_reversal.instance.balance.cents).to eq(500)
    expect(registry.event_log.map(&:name)).to eq(["Opened", "Opened", "Deposited", "DepositCorrected"])
  end

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

    expect {
      dispatcher.dispatch("CorrectsAsSmoke::Box.ReverseDeposit", number: { value: "b-1" }, amount: { cents: 999 })
    }.to raise_error(Hecks::Runtime::GivenNotMet)

    reversed = dispatcher.dispatch("CorrectsAsSmoke::Box.ReverseDeposit", number: { value: "b-1" }, amount: { cents: 1000 })
    expect(reversed.instance.balance.cents).to eq(0)
  end

  it "refuses reverses: true at build time when the original used a lossy op" do
    expect {
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
    }.to raise_error(Hecks::Bluebook::DSL::Malformed, /not statically invertible/)
  end
end
