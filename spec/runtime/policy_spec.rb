
require "spec_helper"

RSpec.describe "a policy" do
  REFLEX_BLUEBOOK = File.join(InMemoryDomain::ROOT, "spec/fixtures/reflex.bluebook")

  def boot_reflex
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(REFLEX_BLUEBOOK)
      Hecksagain::Runtime::Loader.bind_runtime(
        Hecksagain::Runtime::Dispatcher.new(registry)
      )
    end
  end

  def topped_pizza(runtime)
    # `name:` was written TWICE here — once bare, once as the value object — and
    # Ruby warned on every run while silently keeping the second.
    pizza = runtime.dispatch("Pizzas::Order.CreatePizza",
                             name: { value: "Margherita" }, pizza: { price_cents: { cents: 900 }, size: { value: "small" } })
    runtime.dispatch("Pizzas::Order.AddTopping", name: pizza.id, topping: { value: "Basil" }, amount: { value: 3 })
    pizza
  end

  it "fires the command its event names, and the reaction lands" do
    runtime = boot_reflex
    runtime.dispatch("Reflex::Light.Flip", name: { value: "light-1" }, id: "light-1")

    expect(Reflex::Light.find("light-1").condition.to_h).to eq(value: "logged")

    expect(runtime.reactions).to contain_exactly(
      hash_including(policy: "LogOnFlip", on: "Flipped",
                     trigger: "Reflex::Light.Log", delivered: true)
    )
  end

  it "fires once per matching event, not once per declaration site" do
    runtime = boot_reflex
    # TWO DISTINCT LIGHTS — `name:` is what Light is identified by; `id:` was
    # never anything but an unread decoy. The second dispatch used to collide
    # with the first (same `name:`, silently overwritten) and still pass,
    # because nothing checked whether a creating command's identity already
    # existed. AlreadyExists (see command_interpreter.rb) caught it.
    runtime.dispatch("Reflex::Light.Flip", name: { value: "light-1" }, id: "light-1")
    runtime.dispatch("Reflex::Light.Flip", name: { value: "light-2" }, id: "light-2")

    expect(runtime.reactions.size).to eq(2)
  end

  it "stops a reaction that feeds itself, and says so" do
    runtime = boot_reflex
    runtime.dispatch("Reflex::Echo.Install", name: { value: "bell-1" })
    runtime.dispatch("Reflex::Echo.Ring", name: { value: "bell-1" })

    expect(runtime.reactions.size).to eq(Hecksagain::Runtime::Dispatcher::MAX_REACTION_DEPTH + 1)

    stopped = runtime.reactions.select { |r| r[:delivered] == false }
    expect(stopped.size).to eq(1)
    expect(stopped.first[:reason]).to match(/reaction depth \d+ reached/)
  end

  it "records a reaction it cannot deliver rather than swallowing it" do
    runtime = boot_reflex
    runtime.dispatch("Reflex::Beacon.Raise", signal: { value: "beacon-1" })

    expect(runtime.reactions).to contain_exactly(
      hash_including(
        policy:    "NotifyOnRaise",
        on:        "Raised",
        trigger:   "Notifications::Notifications.Send",
        delivered: false
      )
    )
    expect(runtime.reactions.first[:reason]).to match(/no domain "Notifications" loaded/)
  end

  it "leaves the triggering command's own state committed" do
    runtime = boot_in_memory
    pizza   = topped_pizza(runtime)
    runtime.dispatch("Pizzas::Order.Purchase", name: pizza.id, customer_name: { value: "Chris" }, amount: { cents: 900 })

    expect(Pizzas::Order.find(pizza.id).status).to eq("sold")
  end

  # `reaction_defects_spec.rb` proves the split at PolicyInterpreter's own
  # level, in isolation. This proves it end to end, through the SAME
  # `Dispatcher#dispatch` a real caller uses : the triggering command
  # (`Flip`) has already succeeded and persisted by the time its own
  # `Flipped` event fires `LogOnFlip`, and a genuine defect in the
  # REACTION's target must not reach back and fail the caller's own
  # dispatch for a command it already got right.
  #
  # `reenter` is overridden on this one `runtime` instance, not stubbed with
  # a mocking framework this codebase otherwise never reaches for — the
  # override only intercepts the one verb this test cares about breaking
  # (`Reflex::Light.Log`, `LogOnFlip`'s own trigger) and calls straight
  # through to the real dispatch for everything else, so `Flip` itself, and
  # every other path this fixture exercises, runs unmodified.
  it "keeps the triggering command's own success when the reaction it fires is a defect, not a refusal" do
    runtime = boot_reflex
    real_reenter = runtime.method(:reenter)
    runtime.define_singleton_method(:reenter) do |verb, **args|
      raise NoMethodError, "undefined method `boom' for nil" if verb == "Reflex::Light.Log"

      real_reenter.call(verb, **args)
    end

    result = nil
    expect { result = runtime.dispatch("Reflex::Light.Flip", name: { value: "light-1" }, id: "light-1") }
      .to output(/LogOnFlip.*Flipped.*Reflex::Light\.Log.*boom/m).to_stderr

    expect(result.events.map(&:name)).to eq(["Flipped"])
    expect(Reflex::Light.find("light-1").condition.to_h).to eq(value: "on")

    expect(runtime.reactions).to contain_exactly(
      hash_including(policy: "LogOnFlip", on: "Flipped", trigger: "Reflex::Light.Log",
                     delivered: false, defect: true, error_class: "NoMethodError")
    )
  end

  # `where` (a conditional guard on whether a policy fires) and `for_each`
  # (fan-out — the same trigger dispatched once per row a query answers,
  # instead of once for the event) — new language surface, not a bug fix.
  # Built INLINE (`Hecks.bluebook "Fanout" do ... end`), not a fixture
  # file: `spec/fixtures/**/*.bluebook` is swept into
  # `spec/parser_parity_spec.rb`'s own byte-exact Rust comparison
  # automatically (STAGE 5's own "EVERY member" merge), and the Rust
  # parser does not build `where`/`for_each` yet (a deliberate, named
  # `PENDING_PAIRS` entry — see `spec/parser_coverage_spec.rb`) — an
  # inline bluebook never reaches that scan at all, the same reason
  # `spec/dsl_spec.rb`'s own `build_bluebook` helper builds inline rather
  # than from a file.
  describe "where and for_each" do
    def boot_fanout
      registry = Hecksagain::Runtime::Registry.new

      Hecksagain.with_registry(registry) do
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
              then_set :customer_id, to: :customer_id
              then_set :risk,        to: :risk
              emits "Flagged"
            end

            command "Acknowledge" do
              role "Ops"
              goal "acknowledge a customer was reviewed"
              reference_to Customer
              attribute :risk, RiskLevel, optional: true
              then_set :risk, to: { value: "acknowledged" }
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
              then_set :account_id,  to: :account_id
              then_set :customer_id, to: :customer_id
              then_set :status,      to: { value: "open" }
              emits "Opened"
            end

            command "Review" do
              role "Ops"
              goal "open a review on an account"
              reference_to Account
              attribute :customer_id, AccountCustomerId, optional: true
              attribute :risk,        String,            optional: true
              then_set :status, to: { value: "reviewing" }
              emits "Reviewed"
            end

            query "OpenForCustomer" do
              attribute :customer_id, AccountCustomerId
              where(customer_id: :customer_id, "status.value": "open")
            end
          end

          # THE GUARD ALONE — no for_each, isolates `where` on its own.
          policy "NotifyOnFlag" do
            on      "Customer.Flagged"
            where { risk == "high" }
            trigger "Customer.Acknowledge"
          end

          # THE GUARD AND THE FAN-OUT TOGETHER — the task's own worked
          # example ("for each open Account belonging to this Customer,
          # trigger AccountFreezeReview.Open"), self-contained in one
          # domain rather than crossing `across`.
          policy "ReviewOnFlag" do
            on       "Customer.Flagged"
            where { risk == "high" }
            for_each "Account.OpenForCustomer"
            trigger  "Account.Review"
          end
        end

        Hecks.hecksagon("Fanout") do
          ::Fanout::Customer.persisted_by("Memory")
          ::Fanout::Account.persisted_by("Memory")
        end
      end

      Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
    end

    def open_two_accounts_for(runtime, customer_id)
      runtime.dispatch("Fanout::Account.Open", account_id: { value: "#{customer_id}-a1" },
                                               customer_id: { value: customer_id })
      runtime.dispatch("Fanout::Account.Open", account_id: { value: "#{customer_id}-a2" },
                                               customer_id: { value: customer_id })
    end

    it "dispatches when the where clause holds" do
      runtime = boot_fanout
      open_two_accounts_for(runtime, "c1")

      runtime.dispatch("Fanout::Customer.Flag", customer_id: { value: "c1" }, risk: { value: "high" })

      expect(runtime.reactions).to include(
        hash_including(policy: "NotifyOnFlag", on: "Flagged", trigger: "Fanout::Customer.Acknowledge",
                       delivered: true)
      )
      expect(Fanout::Customer.find("c1").risk[:value]).to eq("acknowledged")
    end

    it "skips silently — no reaction_log entry at all — when the where clause does not hold" do
      runtime = boot_fanout
      open_two_accounts_for(runtime, "c1")

      runtime.dispatch("Fanout::Customer.Flag", customer_id: { value: "c1" }, risk: { value: "low" })

      expect(runtime.reactions).to be_empty
      expect(Fanout::Customer.find("c1").risk[:value]).to eq("low")
    end

    it "fans a for_each policy out once per row a query answers, not once for the event" do
      runtime = boot_fanout
      open_two_accounts_for(runtime, "c1")
      # A THIRD account, a DIFFERENT customer — proves the fan-out is
      # scoped by the query's own where, not "every Account that exists".
      runtime.dispatch("Fanout::Account.Open", account_id: { value: "c2-a1" }, customer_id: { value: "c2" })

      runtime.dispatch("Fanout::Customer.Flag", customer_id: { value: "c1" }, risk: { value: "high" })

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
      # Already reviewing — Account has no lifecycle/transition guard of
      # its own here, so this dispatch does not refuse ; the refusal this
      # test actually reaches for is the SAME payload-gate refusal the
      # earlier plain-`trigger` smoke test found (Account.Review would
      # refuse if it did not declare a field the event forwards), proven
      # here by naming a for_each query on an aggregate that has none —
      # a real, ordinary UnknownVerb refusal, recorded and not fatal.
      registry = runtime.registry
      registry.bluebook("Fanout").policies.find { |p| p.name == "ReviewOnFlag" }
              .instance_variable_set(:@for_each, "Account.NoSuchQuery")

      runtime.dispatch("Fanout::Customer.Flag", customer_id: { value: "c1" }, risk: { value: "high" })

      review = runtime.reactions.find { |r| r[:policy] == "ReviewOnFlag" }
      expect(review).to include(delivered: false)
      expect(review[:reason]).to match(/no query/)
    end
  end
end
