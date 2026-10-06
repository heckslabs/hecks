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
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end
  end

  def flip(runtime, name = "light-1")
    runtime.dispatch_flat("Reflex::Light.Flip", name: { value: name }, id: name)
  end

  def light_condition(name) = Reflex::Light.find(name).condition.to_h

  def logged_flip_reaction
    hash_including(policy: "LogOnFlip", on: "Flipped", trigger: "Reflex::Light.Log", delivered: true)
  end

  def defect_reaction
    hash_including(policy: "LogOnFlip", on: "Flipped", trigger: "Reflex::Light.Log",
                   delivered: false, defect: true, error_class: "NoMethodError")
  end

  def undeliverable_reaction
    hash_including(policy: "NotifyOnRaise", on: "Raised", trigger: "Notifications::Notifications.Send", delivered: false)
  end

  def ringing_runtime
    runtime = boot_reflex
    runtime.dispatch_flat("Reflex::Echo.Install", name: { value: "bell-1" })
    runtime.dispatch_flat("Reflex::Echo.Ring", name: { value: "bell-1" })
    runtime
  end

  # Makes only `Reflex::Light.Log` a defect; every other verb runs the real dispatch.
  def break_log_reaction(runtime)
    real_reenter = runtime.method(:reenter)
    runtime.define_singleton_method(:reenter) do |verb, **args|
      raise NoMethodError, "undefined method `boom' for nil" if verb == "Reflex::Light.Log"

      real_reenter.call(verb, **args)
    end
  end

  def flip_with_defect_report(runtime)
    result = nil
    expect { result = flip(runtime) }.to output(/LogOnFlip.*Flipped.*Reflex::Light\.Log.*boom/m).to_stderr
    result
  end

  def topped_pizza(runtime)
    pizza = runtime.dispatch_flat("Pizzas::Order.CreatePizza",
                                  name: { value: "Margherita" }, pizza: { price_cents: { cents: 900 }, size: { value: "small" } })
    runtime.dispatch_flat("Pizzas::Order.AddTopping", name: pizza.id, topping: { value: "Basil" }, amount: { value: 3 })
    pizza
  end

  it "fires the command its event names, and the reaction lands", :aggregate_failures do
    runtime = boot_reflex
    flip(runtime)

    expect(light_condition("light-1")).to eq(value: "logged")
    expect(runtime.reactions).to contain_exactly(logged_flip_reaction)
  end

  it "fires once per matching event, not once per declaration site" do
    runtime = boot_reflex
    # Two distinct lights: `name:` is the identity, `id:` an unread decoy. Reusing a
    # name would overwrite silently and still pass, but AlreadyExists catches it.
    flip(runtime, "light-1")
    flip(runtime, "light-2")

    expect(runtime.reactions.size).to eq(2)
  end

  it "stops a reaction that feeds itself, and says so", :aggregate_failures do
    runtime = ringing_runtime

    expect(runtime.reactions.size).to eq(Hecks::Runtime::Dispatcher::MAX_REACTION_DEPTH + 1)

    stopped = runtime.reactions.select { |r| r[:delivered] == false }
    expect(stopped.size).to eq(1)
    expect(stopped.first[:reason]).to match(/reaction depth \d+ reached/)
  end

  it "records a reaction it cannot deliver rather than swallowing it", :aggregate_failures do
    runtime = boot_reflex
    runtime.dispatch_flat("Reflex::Beacon.Raise", signal: { value: "beacon-1" })

    expect(runtime.reactions).to contain_exactly(undeliverable_reaction)
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
  it "keeps the triggering command's own success when the reaction it fires is a defect, not a refusal", :aggregate_failures do
    runtime = boot_reflex
    break_log_reaction(runtime)

    result = flip_with_defect_report(runtime)

    expect([result.events.map(&:name), light_condition("light-1")]).to eq([["Flipped"], { value: "on" }])
    expect(runtime.reactions).to contain_exactly(defect_reaction)
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
          attaches "Governance"
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

    let(:runtime) { boot_fanout.tap { |booted| open_two_accounts_for(booted, "c1") } }

    def flag(runtime, risk)
      runtime.dispatch_flat("Fanout::Customer.Flag", customer_id: { value: "c1" }, risk: { value: risk })
    end

    def review_reactions(runtime) = runtime.reactions.select { |r| r[:policy] == "ReviewOnFlag" }

    def account_status(id) = Fanout::Account.find(id).status[:value]

    it "dispatches when the where clause holds", :aggregate_failures do
      flag(runtime, "high")

      expect(runtime.reactions).to include(
        hash_including(policy: "NotifyOnFlag", on: "Flagged", trigger: "Fanout::Customer.Acknowledge", delivered: true)
      )
      expect(Fanout::Customer.find("c1").risk[:value]).to eq("acknowledged")
    end

    it "skips silently — no reaction_log entry at all — when the where clause does not hold", :aggregate_failures do
      flag(runtime, "low")

      expect(runtime.reactions).to be_empty
      expect(Fanout::Customer.find("c1").risk[:value]).to eq("low")
    end

    it "fans a for_each policy out once per row a query answers, not once for the event", :aggregate_failures do
      # A different customer's account proves the fan-out is scoped by the query's `where`.
      runtime.dispatch_flat("Fanout::Account.Open", account_id: { value: "c2-a1" }, customer_id: { value: "c2" })
      flag(runtime, "high")

      expect(review_reactions(runtime).map { |r| r[:for_row] }).to contain_exactly("c1-a1", "c1-a2")
      expect(review_reactions(runtime)).to all(include(trigger: "Fanout::Account.Review", delivered: true))
      expect(["c1-a1", "c1-a2", "c2-a1"].map { |id| account_status(id) }).to eq(["reviewing", "reviewing", "open"])
    end

    it "records a for_each row it cannot deliver as a refusal, and still delivers the rest", :aggregate_failures do
      # Naming a query the aggregate lacks forces an ordinary UnknownVerb refusal,
      # which must be recorded and not fatal.
      runtime.registry.bluebook("Fanout").policies.find { |p| p.name == "ReviewOnFlag" }
             .instance_variable_set(:@for_each, "Account.NoSuchQuery")
      flag(runtime, "high")

      expect(review_reactions(runtime).first).to include(delivered: false, reason: a_string_including("no query"))
    end
  end
end
