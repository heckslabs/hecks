require "spec_helper"

RSpec.describe "a policy" do
  REFLEX_BLUEBOOK = File.join(InMemoryDomain::ROOT, "spec/fixtures/reflex.bluebook")

  def boot_reflex
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(REFLEX_BLUEBOOK)
      Hecks::Runtime::Loader.bind_runtime(
        Hecks::Runtime::Dispatcher.new(registry)
      )
    end
  end

  def topped_pizza(runtime)
    pizza = runtime.dispatch_flat("Pizzas::Order.CreatePizza",
                                  name: { value: "Margherita" }, pizza: { price_cents: { cents: 900 }, size: { value: "small" } })
    runtime.dispatch_flat("Pizzas::Order.AddTopping", name: pizza.id, topping: { value: "Basil" }, amount: { value: 3 })
    pizza
  end

  it "fires the command its event names, and the reaction lands" do
    runtime = boot_reflex
    runtime.dispatch_flat("Reflex::Light.Flip", name: { value: "light-1" }, id: "light-1")

    expect(Reflex::Light.find("light-1").condition.to_h).to eq(value: "logged")

    expect(runtime.reactions).to contain_exactly(
      hash_including(policy: "LogOnFlip", on: "Flipped",
                     trigger: "Reflex::Light.Log", delivered: true)
    )
  end

  it "fires once per matching event, not once per declaration site" do
    runtime = boot_reflex
    # Two distinct lights: `name:` is the identity, `id:` an unread decoy. Reusing a
    # name would overwrite silently and still pass, but AlreadyExists catches it.
    runtime.dispatch_flat("Reflex::Light.Flip", name: { value: "light-1" }, id: "light-1")
    runtime.dispatch_flat("Reflex::Light.Flip", name: { value: "light-2" }, id: "light-2")

    expect(runtime.reactions.size).to eq(2)
  end

  it "stops a reaction that feeds itself, and says so" do
    runtime = boot_reflex
    runtime.dispatch_flat("Reflex::Echo.Install", name: { value: "bell-1" })
    runtime.dispatch_flat("Reflex::Echo.Ring", name: { value: "bell-1" })

    expect(runtime.reactions.size).to eq(Hecks::Runtime::Dispatcher::MAX_REACTION_DEPTH + 1)

    stopped = runtime.reactions.select { |r| r[:delivered] == false }
    expect(stopped.size).to eq(1)
    expect(stopped.first[:reason]).to match(/reaction depth \d+ reached/)
  end

  it "records a reaction it cannot deliver rather than swallowing it" do
    runtime = boot_reflex
    runtime.dispatch_flat("Reflex::Beacon.Raise", signal: { value: "beacon-1" })

    expect(runtime.reactions).to contain_exactly(
      hash_including(
        policy:    "NotifyOnRaise",
        on:        "Raised",
        trigger:   "Notifications::Notifications.Send",
        delivered: false
      )
    )
    expect(runtime.reactions.first[:reason]).to include('no domain "Notifications" loaded')
  end

  it "leaves the triggering command's own state committed" do
    runtime = boot_in_memory
    pizza   = topped_pizza(runtime)
    runtime.dispatch_flat("Pizzas::Order.Purchase", name: pizza.id, customer_name: { value: "Chris" }, amount: { cents: 900 })

    expect(Pizzas::Order.find(pizza.id).status).to eq("sold")
  end

  # End to end through `Dispatcher#dispatch`: `Flip` has already persisted when `LogOnFlip`
  # fires, so a defect in the reaction's target must not fail the caller's dispatch.
  #
  # `reenter` is overridden on this one runtime rather than stubbed; only
  # `Reflex::Light.Log` is broken and every other verb runs the real dispatch.
  it "keeps the triggering command's own success when the reaction it fires is a defect, not a refusal" do
    runtime = boot_reflex
    real_reenter = runtime.method(:reenter)
    runtime.define_singleton_method(:reenter) do |verb, **args|
      raise NoMethodError, "undefined method `boom' for nil" if verb == "Reflex::Light.Log"

      real_reenter.call(verb, **args)
    end

    result = nil
    expect { result = runtime.dispatch_flat("Reflex::Light.Flip", name: { value: "light-1" }, id: "light-1") }
      .to output(/LogOnFlip.*Flipped.*Reflex::Light\.Log.*boom/m).to_stderr

    expect(result.events.map(&:name)).to eq(["Flipped"])
    expect(Reflex::Light.find("light-1").condition.to_h).to eq(value: "on")

    expect(runtime.reactions).to contain_exactly(
      hash_including(policy: "LogOnFlip", on: "Flipped", trigger: "Reflex::Light.Log",
                     delivered: false, defect: true, error_class: "NoMethodError")
    )
  end

  # `where` guards whether a policy fires; `for_each` dispatches the trigger once per row a
  # query answers. Built inline because fixture bluebooks are swept into
  # `spec/parser_parity_spec.rb`, and the Rust parser lacks both (`PENDING_PAIRS`).
  describe "where and for_each" do
    # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength
    def boot_fanout
      registry = Hecks::Runtime::Registry.new

      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)

        Hecks.bluebook "Fanout" do
          aggregate "Customer" do
            identified_by :customer_id
            attribute :customer_id, CustomerId
            attribute :risk,        RiskLevel

            value_object("CustomerId") { attribute :value, String }
            value_object("RiskLevel")  { attribute :value, String }

            command "Flag" do
              role "Ops"
              goal "flag a customer's risk level"
              attribute :customer_id, CustomerId
              attribute :risk,        RiskLevel
              sets :customer_id
              sets :risk
              emits "Flagged"
            end

            command "Acknowledge" do
              role "Ops"
              goal "acknowledge a customer was reviewed"
              reference_to Customer
              attribute :risk, RiskLevel, optional: true
              sets :risk, to: { value: "acknowledged" }
              emits "Acknowledged"
            end
          end

          aggregate "Account" do
            identified_by :account_id
            attribute :account_id,  AccountId
            attribute :customer_id, AccountCustomerId
            attribute :status,      AccountStatus

            value_object("AccountId")         { attribute :value, String }
            value_object("AccountCustomerId") { attribute :value, String }
            value_object("AccountStatus")     { attribute :value, String }

            command "Open" do
              role "Ops"
              goal "open an account"
              attribute :account_id,  AccountId
              attribute :customer_id, AccountCustomerId
              sets :account_id
              sets :customer_id
              sets :status, to: { value: "open" }
              emits "Opened"
            end

            command "Review" do
              role "Ops"
              goal "open a review on an account"
              reference_to Account
              attribute :customer_id, AccountCustomerId, optional: true
              attribute :risk,        String,            optional: true
              sets :status, to: { value: "reviewing" }
              emits "Reviewed"
            end

            query "OpenForCustomer" do
              attribute :customer_id, AccountCustomerId
              where(customer_id: :customer_id, "status.value": "open")
            end
          end

          # The guard alone, isolating `where`.
          policy "NotifyOnFlag" do
            on      "Customer.Flagged"
            where { risk == "high" }
            trigger Customer::Acknowledge
          end

          # The guard and the fan-out together, within one domain rather than `across`.
          policy "ReviewOnFlag" do
            on "Customer.Flagged"
            where { risk == "high" }
            for_each "Account.OpenForCustomer"
            trigger  Account::Review
          end
        end

        Hecks.hecksagon("Fanout") do
          uses_framework "Governance"
          Fanout::Customer.persisted_by("Memory")
          Fanout::Account.persisted_by("Memory")
        end
        Hecks.hecksagon("Governance") do
          Governance::RoleAssignment.persisted_by("Memory")
          Governance::RoleTransition.persisted_by("Memory")
        end
      end

      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end

    def open_two_accounts_for(runtime, customer_id)
      runtime.dispatch_flat("Fanout::Account.Open", account_id:  { value: "#{customer_id}-a1" },
                                                    customer_id: { value: customer_id })
      runtime.dispatch_flat("Fanout::Account.Open", account_id:  { value: "#{customer_id}-a2" },
                                                    customer_id: { value: customer_id })
    end

    it "dispatches when the where clause holds" do
      runtime = boot_fanout
      open_two_accounts_for(runtime, "c1")

      runtime.dispatch_flat("Fanout::Customer.Flag", customer_id: { value: "c1" }, risk: { value: "high" })

      expect(runtime.reactions).to include(
        hash_including(policy: "NotifyOnFlag", on: "Flagged", trigger: "Fanout::Customer.Acknowledge",
                       delivered: true)
      )
      expect(Fanout::Customer.find("c1").risk[:value]).to eq("acknowledged")
    end

    it "skips silently — no reaction_log entry at all — when the where clause does not hold" do
      runtime = boot_fanout
      open_two_accounts_for(runtime, "c1")

      runtime.dispatch_flat("Fanout::Customer.Flag", customer_id: { value: "c1" }, risk: { value: "low" })

      expect(runtime.reactions).to be_empty
      expect(Fanout::Customer.find("c1").risk[:value]).to eq("low")
    end

    it "fans a for_each policy out once per row a query answers, not once for the event" do
      runtime = boot_fanout
      open_two_accounts_for(runtime, "c1")
      # A different customer's account proves the fan-out is scoped by the query's `where`.
      runtime.dispatch_flat("Fanout::Account.Open", account_id: { value: "c2-a1" }, customer_id: { value: "c2" })

      runtime.dispatch_flat("Fanout::Customer.Flag", customer_id: { value: "c1" }, risk: { value: "high" })

      review_reactions = runtime.reactions.select { |r| r[:policy] == "ReviewOnFlag" }
      expect(review_reactions.size).to eq(2)
      expect(review_reactions.map { |r| r[:for_row] }).to contain_exactly("c1-a1", "c1-a2")
      expect(review_reactions).to all(include(trigger: "Fanout::Account.Review", delivered: true))

      expect(Fanout::Account.find("c1-a1").status[:value]).to eq("reviewing")
      expect(Fanout::Account.find("c1-a2").status[:value]).to eq("reviewing")
      expect(Fanout::Account.find("c2-a1").status[:value]).to eq("open")
    end

    it "records a for_each row it cannot deliver as a refusal, and still delivers the rest" do
      runtime = boot_fanout
      open_two_accounts_for(runtime, "c1")
      # Naming a query the aggregate lacks forces an ordinary UnknownVerb refusal,
      # which must be recorded and not fatal.
      registry = runtime.registry
      registry.bluebook("Fanout").policies.find { |p| p.name == "ReviewOnFlag" }
              .instance_variable_set(:@for_each, "Account.NoSuchQuery")

      runtime.dispatch_flat("Fanout::Customer.Flag", customer_id: { value: "c1" }, risk: { value: "high" })

      review = runtime.reactions.find { |r| r[:policy] == "ReviewOnFlag" }
      expect(review).to include(delivered: false)
      expect(review[:reason]).to include("no query")
    end
  end
end
