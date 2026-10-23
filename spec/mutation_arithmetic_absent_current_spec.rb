require "spec_helper"

# Arithmetic on a never-set VO-typed attribute reads the absent current as zero and unwraps the
# amount's numeric field; the semantics corpus holds that, in
# numeric_effects_absent_target_and_operand. This pins the one case it must refuse: a source
# value with more than one numeric field.
RSpec.describe "arithmetic on a VO-typed attribute that was never set" do
  # One inline bluebook, declared whole: splitting the DSL block would scatter the fixture.
  # rubocop:disable-next Metrics/AbcSize
  # rubocop:disable-next Metrics/MethodLength
  def boot(&binds)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!

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

  it "refuses rather than guesses when the source value has more than one numeric field" do
    runtime.dispatch_flat("ArithmeticAbsentCurrent::Wallet.Open", label: { value: "w1" })

    expect do
      runtime.dispatch_flat("ArithmeticAbsentCurrent::Wallet.IncrementAmbiguous", label: "w1", pair: { a: 1, b: 2 })
    end.to raise_error(Hecks::Runtime::TypeMismatch)
  end
end
