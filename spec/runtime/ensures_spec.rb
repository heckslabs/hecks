
require "spec_helper"

# The postcondition — Design by Contract's third leg, `given` being the
# first and `invariant` the second. Checked against the SETTLED record,
# after mutations and the lifecycle move, before anything persists —
# `old` names the state as the givens saw it.
RSpec.describe "a command's ensures" do
  def boot(chapter = "Vault", &domain)
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Hecks.bluebook(chapter, &domain)
    end
    Hecksagain::Runtime::Dispatcher.new(registry)
  end

  # A scratch domain, not a corpus fixture — one command whose postcondition
  # holds, one whose does not, so the failing path is provoked on purpose
  # rather than hoped for out of a real domain's correct arithmetic.
  def vault
    boot do
      vision "A box that only ever grows, or refuses to have grown wrong."
      core

      aggregate "Box" do
        identified_by :number

        attribute :number,  Number
        attribute :balance, Money, default: { cents: 0 }

        value_object "Number" do
          attribute :value, String
        end

        value_object "Money" do
          attribute :cents, Integer
        end

        command "Open" do
          role "Teller"
          goal "Bring a box into being"

          attribute :number, Number

          emits "Opened"
        end

        command "Deposit" do
          role "Teller"
          goal "Add cents, and prove the balance moved by exactly that much"

          reference_to Box
          attribute :amount, Money

          then_set :balance, increment: :amount

          ensures("the balance grew by exactly the deposit") do
            balance.cents == old.balance.cents + amount.cents
          end

          emits "Deposited"
        end

        command "Overstate" do
          role "Teller"
          goal "Add cents, but claim double — the postcondition this command breaks on purpose"

          reference_to Box
          attribute :amount, Money

          then_set :balance, increment: :amount

          ensures("the balance grew by exactly double the deposit") do
            balance.cents == old.balance.cents + amount.cents + amount.cents
          end

          emits "Deposited"
        end
      end
    end
  end

  def open_box(runtime)
    runtime.dispatch("Vault::Box.Open", number: { value: "b1" })
    runtime
  end

  it "saves and emits when the postcondition holds" do
    runtime = open_box(vault)

    result = runtime.dispatch("Vault::Box.Deposit", number: { value: "b1" }, amount: { cents: 500 })

    expect(result.instance[:balance][:cents]).to eq(500)
    expect(result.events.map(&:name)).to eq(["Deposited"])
    expect(runtime.registry.repository("Vault", runtime.registry.bluebook("Vault").aggregate("Box"))
                  .find("b1")[:balance][:cents]).to eq(500)
  end

  it "refuses with EnsuresNotMet, in the command's own words, and persists nothing" do
    runtime = open_box(vault)

    expect { runtime.dispatch("Vault::Box.Overstate", number: { value: "b1" }, amount: { cents: 100 }) }
      .to raise_error(Hecksagain::Runtime::EnsuresNotMet,
                      "Overstate refused — the balance grew by exactly double the deposit")

    expect(runtime.registry.repository("Vault", runtime.registry.bluebook("Vault").aggregate("Box"))
                  .find("b1")[:balance][:cents]).to eq(0)
  end

  it "hands `old` the PRE-mutation state, not the post" do
    runtime = open_box(vault)
    runtime.dispatch("Vault::Box.Deposit", number: { value: "b1" }, amount: { cents: 500 })

    # A passing Deposit already proves old != current (0 -> 500 -> 700):
    # if `old` had leaked the post-mutation value, 700 == 500 + 200 would
    # be false and this dispatch would itself raise.
    result = runtime.dispatch("Vault::Box.Deposit", number: { value: "b1" }, amount: { cents: 200 })
    expect(result.instance[:balance][:cents]).to eq(700)
  end

  it "is EnsuresNotMet, is a domain refusal, and reads as the domain judging" do
    expect(Hecksagain::Runtime::DOMAIN_REFUSALS).to include(Hecksagain::Runtime::EnsuresNotMet)
  end

  # ENSURES is the first refusal that ever sits AFTER a mutation — every
  # earlier refusal (given, the payload gate, admissible_transition) runs
  # BEFORE apply_mutations, so nothing before this feature could ever
  # observe a Memory-adapter record half-mutated by a dispatch that then
  # failed. Memory's `find` hands back the SAME object it will eventually
  # save, aliased — so without Instance#dup (and, one level deeper, the
  # array/hash copy in EntityInterpreter#element_of), a refused ensures
  # would still leave the in-memory record mutated. These two specs are
  # that bug, pinned so it cannot come back quietly.
  describe "an aliasing bug ensures was the first feature to expose" do
    def coin
      boot("Coin") do
        vision "One coin, and a purse of coins — the aggregate case and the entity case."
        core

        aggregate "Purse" do
          identified_by :number

          attribute :number, Number
          attribute :total,  Money, default: { cents: 0 }
          attribute :coins,  list_of(Coin)

          value_object "Number" do
            attribute :value, String
          end

          value_object "Money" do
            attribute :cents, Integer
          end

          value_object "Label" do
            attribute :value, String
          end

          value_object "Serial" do
            attribute :value, String
          end

          command "Open" do
            role "Teller"
            goal "Bring a purse into being"
            attribute :number, Number
            emits "Opened"
          end

          command "AddCoin" do
            role "Teller"
            goal "Drop a coin in — a fresh element, so the entity path is exercised too"
            reference_to Purse
            attribute :serial, Serial
            attribute :label,  Label
            attribute :cents,  Money

            then_set :coins, append: { serial: :serial, label: :label, cents: :cents }
            then_set :total, increment: :cents

            emits "CoinAdded"
          end

          command "TotalUp" do
            role "Teller"
            goal "Claim a total the mutation does not actually reach — refuses on purpose"
            reference_to Purse

            then_set :total, increment: { cents: 1 }

            ensures("the claimed total never holds") { total.cents == old.total.cents }

            emits "ToppedUp"
          end

          entity "Coin" do
            # A SEPARATE identity field, deliberately not `label` — the
            # argument that ADDRESSES an element and a state field of the
            # same name collide in expression scope (args win over state,
            # the same rule `given` already lives under), and colliding
            # them here would make `label.value` in the ensures read the
            # dispatch's addressing argument instead of the settled record.
            identified_by :serial
            attribute :serial, Serial
            attribute :label,  Label
            attribute :cents,  Integer

            command "Reface" do
              role "Teller"
              goal "Relabel a coin, but claim it did not move — refuses on purpose"
              attribute :new_label, Label

              then_set :label, to: :new_label

              ensures("the claimed label never moves") { label.value == old.label.value }

              emits "Refaced"
            end
          end
        end
      end
    end

    it "leaves the aggregate untouched in Memory when an ensures after apply_mutations refuses" do
      runtime = coin
      runtime.dispatch("Coin::Purse.Open", number: { value: "p1" })

      expect { runtime.dispatch("Coin::Purse.TotalUp", number: { value: "p1" }) }
        .to raise_error(Hecksagain::Runtime::EnsuresNotMet)

      stored = runtime.registry.repository("Coin", runtime.registry.bluebook("Coin").aggregate("Purse")).find("p1")
      expect(stored[:total][:cents]).to eq(0)
    end

    it "leaves an entity element untouched in Memory when its own ensures refuses" do
      runtime = coin
      runtime.dispatch("Coin::Purse.Open", number: { value: "p1" })
      runtime.dispatch("Coin::Purse.AddCoin", number: { value: "p1" }, serial: { value: "c1" }, label: { value: "heads" }, cents: { cents: 25 })

      expect { runtime.dispatch("Coin::Purse.Coin.Reface", number: { value: "p1" }, serial: { value: "c1" }, new_label: { value: "tails" }) }
        .to raise_error(Hecksagain::Runtime::EnsuresNotMet)

      stored = runtime.registry.repository("Coin", runtime.registry.bluebook("Coin").aggregate("Purse")).find("p1")
      expect(stored[:coins].first[:label][:value]).to eq("heads")
    end
  end
end
