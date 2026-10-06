require "spec_helper"

# The postcondition, checked against the settled record after mutations and before persisting;
# `old` is the state the givens saw.
RSpec.describe "a command's ensures" do
  def boot(chapter = "Vault", &domain)
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Hecks.bluebook(chapter, &domain)
    end
    Hecks::Runtime::Dispatcher.new(registry)
  end

  # A scratch domain: one command whose postcondition holds and one whose does not.
  # Declared as one bluebook block so the whole domain reads in one place.
  # rubocop:disable-next Metrics/AbcSize
  # rubocop:disable-next Metrics/MethodLength
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

          sets :balance, increment: :amount

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

          sets :balance, increment: :amount

          ensures("the balance grew by exactly double the deposit") do
            balance.cents == old.balance.cents + amount.cents + amount.cents
          end

          emits "Deposited"
        end
      end
    end
  end

  def open_box(runtime)
    runtime.dispatch_flat("Vault::Box.Open", number: { value: "b1" })
    runtime
  end

  def stored_record(runtime, chapter, aggregate, id)
    runtime.registry.repository(chapter, runtime.registry.bluebook(chapter).aggregate(aggregate)).find(id)
  end

  def stored_balance(runtime) = stored_record(runtime, "Vault", "Box", "b1")[:balance][:cents]

  def deposit(runtime, verb, cents)
    runtime.dispatch_flat("Vault::Box.#{verb}", number: { value: "b1" }, amount: { cents: cents })
  end

  it "saves and emits when the postcondition holds", :aggregate_failures do
    runtime = open_box(vault)

    result = deposit(runtime, "Deposit", 500)

    expect(result.instance[:balance][:cents]).to eq(500)
    expect(result.events.map(&:name)).to eq(["Deposited"])
    expect(stored_balance(runtime)).to eq(500)
  end

  it "refuses with EnsuresNotMet, in the command's own words, and persists nothing", :aggregate_failures do
    runtime = open_box(vault)

    expect { deposit(runtime, "Overstate", 100) }
      .to raise_error(Hecks::Runtime::EnsuresNotMet,
                      "Overstate refused — the balance grew by exactly double the deposit")

    expect(stored_balance(runtime)).to eq(0)
  end

  it "hands `old` the PRE-mutation state, not the post" do
    runtime = open_box(vault)
    deposit(runtime, "Deposit", 500)

    # A passing Deposit already proves it: if `old` leaked the post-mutation value,
    # 700 == 500 + 200 would fail and this dispatch would raise.
    result = deposit(runtime, "Deposit", 200)
    expect(result.instance[:balance][:cents]).to eq(700)
  end

  it "is EnsuresNotMet, is a domain refusal, and reads as the domain judging" do
    expect(Hecks::Runtime::DOMAIN_REFUSALS).to include(Hecks::Runtime::EnsuresNotMet)
  end

  # Memory's `find` returns the object it will later save, so without Instance#dup (and the
  # copy in EntityInterpreter#element_of) a refused ensures would leave the record mutated.
  describe "an aliasing bug ensures was the first feature to expose" do
    # Same shape as `vault`: one declarative fixture covering the aggregate and entity paths.
    # rubocop:disable-next Metrics/AbcSize
    # rubocop:disable-next Metrics/MethodLength
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

            sets :coins, append: { serial: :serial, label: :label, cents: :cents }
            sets :total, increment: :cents

            emits "CoinAdded"
          end

          command "TotalUp" do
            role "Teller"
            goal "Claim a total the mutation does not actually reach — refuses on purpose"
            reference_to Purse

            sets :total, increment: { cents: 1 }

            ensures("the claimed total never holds") { total.cents == old.total.cents }

            emits "ToppedUp"
          end

          entity "Coin" do
            # Not `label`: an addressing argument and a state field of the same name
            # collide in expression scope, so `label.value` would read the argument.
            identified_by :serial
            attribute :serial, Serial
            attribute :label,  Label
            # `Money`, not `Integer`: entity attribute types resolve as declared references.
            attribute :cents,  Money

            command "Reface" do
              role "Teller"
              goal "Relabel a coin, but claim it did not move — refuses on purpose"
              attribute :new_label, Label

              sets :label, to: :new_label

              ensures("the claimed label never moves") { label.value == old.label.value }

              emits "Refaced"
            end
          end
        end
      end
    end

    def open_purse
      runtime = coin
      runtime.dispatch_flat("Coin::Purse.Open", number: { value: "p1" })
      runtime
    end

    def add_heads_coin(runtime)
      runtime.dispatch_flat("Coin::Purse.AddCoin", number: { value: "p1" }, serial: { value: "c1" },
                            label: { value: "heads" }, cents: { cents: 25 })
    end

    def reface_to_tails(runtime)
      runtime.dispatch_flat("Coin::Purse.Coin.Reface", number: { value: "p1" }, serial: { value: "c1" },
                            new_label: { value: "tails" })
    end

    it "leaves the aggregate untouched in Memory when an ensures after apply_mutations refuses", :aggregate_failures do
      runtime = open_purse

      expect { runtime.dispatch_flat("Coin::Purse.TotalUp", number: { value: "p1" }) }
        .to raise_error(Hecks::Runtime::EnsuresNotMet)

      expect(stored_record(runtime, "Coin", "Purse", "p1")[:total][:cents]).to eq(0)
    end

    it "leaves an entity element untouched in Memory when its own ensures refuses", :aggregate_failures do
      runtime = open_purse
      add_heads_coin(runtime)

      expect { reface_to_tails(runtime) }.to raise_error(Hecks::Runtime::EnsuresNotMet)

      expect(stored_record(runtime, "Coin", "Purse", "p1")[:coins].first[:label][:value]).to eq("heads")
    end
  end
end
