require "tmpdir"

# The smallest domain that reproduces a lost-update race for a state-dependent command: one
# numbered Account whose `Debit` reads `balance` in its `given` and in its `decrement`.
#
# The bluebook is loaded from a file, as a real one is, so the `given` block's source can be read.
module ConcurrencyGapDomain
  # The Account bluebook, named `name`, as Ruby source.
  #
  # @param name [String] the domain name the bluebook declares
  # @param vision [String] the sentence the bluebook's vision carries
  # @return [String] the bluebook source
  def self.source(name, vision)
    <<~BLUEBOOK
      Hecks.bluebook #{name.inspect} do
        vision #{vision.inspect}

        aggregate "Account" do
          description "One numbered account and its own balance in cents."

          identified_by :number

          attribute :number,  AccountNumber
          attribute :balance, Money, default: { cents: 0 }

          value_object "AccountNumber" do
            attribute :value, String
          end

          value_object "Money" do
            attribute :cents, Integer
            invariant("a balance is never negative") { cents >= 0 }
          end

          command "Open" do
            goal "Start a fresh account with an opening balance"

            attribute :number,  AccountNumber
            attribute :balance, Money

            sets :number
            sets :balance

            emits "AccountOpened"
          end

          command "Debit" do
            goal "Take cents out of the account, if the balance covers it"

            reference_to Account
            attribute :amount, Money

            given("the balance covers it") { balance.cents >= amount.cents }

            sets :balance, decrement: :amount

            emits "AccountDebited"
          end
        end
      end
    BLUEBOOK
  end

  # Declares the Account bluebook into the registry in scope (call inside `Hecks.with_registry`).
  #
  # @param name [String] the domain name to declare
  # @param vision [String] the sentence the bluebook's vision carries
  # @return [void]
  def self.declare(name, vision:)
    Dir.mktmpdir("hecks-concurrency-gap-") do |dir|
      path = File.join(dir, "concurrency_gap.bluebook")
      File.write(path, source(name, vision))
      Kernel.load(path)
    end
  end
end
