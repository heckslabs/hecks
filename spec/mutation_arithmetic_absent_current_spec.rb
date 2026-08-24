require "spec_helper"

# CommandRules::Arithmetic's `current ||= 0` (`#arithmetic`/`#multiply`)
# only ever produced a genuine zero when `amount` was ALSO plain — a
# VO-typed attribute with no declared `default:` (genuinely absent, never
# set) hit a misleading refusal on its very first increment/decrement/
# multiply: "increment needs an Integer, got 500" — true of nothing.
# `amount` (500 cents) was exactly the Integer it named, just still
# wearing the Money wrapper the command's own declared attribute type put
# it in; the real gap was that `current` (a raw `0`, not a Value) could
# never enter the value-object branch alongside it.
#
# `#clamp` already falls through to a raw scalar for the identical absent
# case and lets the mutation applier re-wrap the result into the declared
# VO type on write — this closes the same gap for increment/decrement/
# multiply, by unwrapping `amount`'s own single numeric field rather than
# refusing on it.
RSpec.describe "arithmetic on a VO-typed attribute that was never set" do
  def boot(&binds)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      Hecks.bluebook("ArithmeticAbsentCurrent") do
        supporting
        aggregate "Wallet" do
          identified_by :label
          attribute :label, Label
          value_object "Label" do
            attribute :value, String
          end

          # No default: — genuinely absent until a command first sets it.
          attribute :balance, Money, optional: true
          value_object "Money" do
            attribute :cents, Integer
          end

          attribute :ambiguous, TwoNums, optional: true
          value_object "TwoNums" do
            attribute :a, Integer
            attribute :b, Integer
          end

          command "Open" do
            attribute :label, Label
            emits "WalletOpened"
          end

          command "Deposit" do
            reference_to Wallet
            attribute :amount, Money
            sets :balance, increment: :amount
            emits "Deposited"
          end

          command "Withdraw" do
            reference_to Wallet
            attribute :amount, Money
            sets :balance, decrement: :amount
            emits "Withdrawn"
          end

          command "Scale" do
            reference_to Wallet
            attribute :factor, Money
            sets :balance, multiply: :factor
            emits "Scaled"
          end

          command "IncrementAmbiguous" do
            reference_to Wallet
            attribute :pair, TwoNums
            sets :ambiguous, increment: :pair
            emits "AmbiguousIncremented"
          end
        end
      end

      Hecks.hecksagon("ArithmeticAbsentCurrent", &binds)
    end

    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) { boot { ArithmeticAbsentCurrent::Wallet.persisted_by("Memory") } }

  it "increment wraps the raw result back into the declared VO type" do
    runtime.dispatch("ArithmeticAbsentCurrent::Wallet.Open", label: { value: "w1" })
    runtime.dispatch("ArithmeticAbsentCurrent::Wallet.Deposit", label: "w1", amount: { cents: 500 })

    expect(ArithmeticAbsentCurrent::Wallet.find("w1")[:balance].to_h).to eq(cents: 500)
  end

  it "decrement wraps the raw result back into the declared VO type" do
    runtime.dispatch("ArithmeticAbsentCurrent::Wallet.Open", label: { value: "w1" })
    runtime.dispatch("ArithmeticAbsentCurrent::Wallet.Withdraw", label: "w1", amount: { cents: 500 })

    expect(ArithmeticAbsentCurrent::Wallet.find("w1")[:balance].to_h).to eq(cents: -500)
  end

  it "multiply wraps the raw result back into the declared VO type" do
    runtime.dispatch("ArithmeticAbsentCurrent::Wallet.Open", label: { value: "w1" })
    runtime.dispatch("ArithmeticAbsentCurrent::Wallet.Scale", label: "w1", factor: { cents: 7 })

    expect(ArithmeticAbsentCurrent::Wallet.find("w1")[:balance].to_h).to eq(cents: 0)
  end

  it "refuses rather than guesses when the source value has more than one numeric field" do
    runtime.dispatch("ArithmeticAbsentCurrent::Wallet.Open", label: { value: "w1" })

    expect do
      runtime.dispatch("ArithmeticAbsentCurrent::Wallet.IncrementAmbiguous", label: "w1", pair: { a: 1, b: 2 })
    end.to raise_error(Hecks::Runtime::TypeMismatch)
  end
end
