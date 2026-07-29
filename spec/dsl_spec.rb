require "hecksagain"

RSpec.describe "the DSL surface" do
  def in_registry
    registry = Hecksagain::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      yield
    end
    registry
  end

  def build_bluebook(name, &block)
    in_registry { Hecks.bluebook(name, &block) }.bluebook(name)
  end

  def build_aggregate(domain, &block)
    build_bluebook(domain) { aggregate("Thing", &block) }.aggregate("Thing")
  end

  def build_command(domain, &block)
    build_aggregate(domain) do
      value_object("Size") { attribute :value, Integer }
      value_object("Tag") { attribute :value, String }
      command("Do", &block)
    end.command("Do")
  end

  describe "Hecks" do
    it ".with_registry collects declarations, and restores the previous one" do
      registry = in_registry { Hecks.bluebook("WithReg") { vision "v" } }

      expect(registry.bluebook("WithReg").vision).to eq("v")
      expect(Hecksagain.current_registry).to be_nil
    end

    it ".bluebook registers a domain" do
      expect(build_bluebook("Registered").name).to eq("Registered")
    end

    it ".bluebook records an optional domain version" do
      registry = in_registry { Hecks.bluebook("Registered", version: "v2") {} }
      expect(registry.bluebook("Registered").version).to eq("v2")
    end

    it ".family registers a family" do
      registry = in_registry { Hecks.port("post") { verb "posted_by" } }
      expect(registry.ports["post"].verb).to eq("posted_by")
    end

    it ".adapter registers an adapter" do
      registry = in_registry { Hecks.adapter("Carrier") { port "post" } }
      expect(registry.adapters["Carrier"].port).to eq("post")
    end

    it ".world registers per-deployment values" do
      registry = in_registry { Hecks.world("Worldly") { posted_by("Carrier") { office "EC1" } } }
      expect(registry.world("Worldly").for_verb("posted_by")).to eq(adapter: "Carrier", office: "EC1")
    end

    it ".hecksagon registers binds" do
      registry = in_registry { Hecks.hecksagon("Hexed") { Hexed::Thing.posted_by("Carrier") } }
      bind = registry.hecksagon("Hexed").binds.first

      expect([bind.aggregate, bind.verb, bind.adapter]).to eq(["Hexed::Thing", "posted_by", "Carrier"])
    end

    it ".boot loads a domain directory and returns the door" do
      runtime = Hecks.boot(File.expand_path("../examples/pizzas", __dir__))
      expect(runtime).to be_a(Hecksagain::Runtime::Dispatcher)
      expect(runtime.verbs).to include("Pizzas::Pizza.Purchase")
    end

    it ".boot refuses a declaration loaded outside a boot" do
      expect { Hecks.bluebook("Orphan") { vision "x" } }
        .to raise_error(Hecksagain::LoadOutsideBoot, /outside a boot/)
    end
  end

  describe "declarations that cannot mean what they say" do
    Malformed = Hecksagain::Bluebook::DSL::Malformed

    it "refuses a vision that says nothing" do
      expect { build_bluebook("Mute") { vision "" } }
        .to raise_error(Malformed, /a vision says something/)
    end

    it "refuses a description that says nothing" do
      expect { build_aggregate("Blank") { description "" } }
        .to raise_error(Malformed, /a description says something/)
    end

    it "refuses an identity that names no field" do
      expect { build_aggregate("Unkeyed") { identified_by "" } }
        .to raise_error(Malformed, /names no field/)
    end

    it "refuses an unnamed attribute" do
      # a DECLARED value-object type, so the value-object-types rule does not
      # fire first and mask the naming rule this example is about
      expect do
        build_aggregate("Nameless") do
          value_object("Label") { attribute :value, String }
          attribute "", Object.const_get("Label") rescue attribute "", :Label
        end
      end.to raise_error(Malformed, /an attribute is named/)
    end

    it "refuses an aggregate attribute that is not a value object" do
      expect { build_aggregate("Primitive") { attribute :code, String } }
        .to raise_error(Malformed, %r{no Shape with id "Primitive::Thing.String"})
    end

    it "refuses a reference to an entity rather than an aggregate head" do
      expect do
        build_bluebook("HeadOnly") do
          aggregate "Root" do
            attribute :key, Key
            value_object("Key") { attribute :value, String }

            entity "Child" do
              command("Change") { reference_to Child }
            end
          end
        end
      end.to raise_error(Malformed, /Root\.Child\.Change references Child; references may only target aggregate heads/)
    end

    it "refuses a reference to a value object rather than an aggregate head" do
      expect do
        build_bluebook("HeadOnly") do
          aggregate "Root" do
            value_object("Code") { attribute :value, String }

            command("UseCode") { reference_to Code }
          end
        end
      end.to raise_error(Malformed, /Root\.UseCode references Code; references may only target aggregate heads/)
    end

    it "refuses an unnamed event" do
      expect { build_command("Silent") { emits "" } }
        .to raise_error(Malformed, /an event is named/)
    end

    it "refuses a mutation that names no operation" do
      expect { build_command("Inert") { then_set :status } }
        .to raise_error(Malformed, /names no operation/)
    end

    it "refuses a mutation that names two operations" do
      expect { build_command("Torn") { then_set :balance, to: 5, increment: :amount } }
        .to raise_error(Malformed, /one mutation, one meaning/)
    end

    it "refuses a command that names its own root twice" do
      expect do
        build_command("Confused") do
          reference_to "Thing"
          reference_to "Thing"
        end
      end.to raise_error(Malformed, /acts on ONE/)
    end

    it "refuses a given whose source could not be read" do
      expect do
        in_registry do
          Hecks.bluebook("Unreadable") do
            aggregate("Thing") do
              command("Do") { given("unreadable", &eval("proc { 1 < 2 }")) }
            end
          end
        end
      end.to raise_error(Malformed, /did not survive extraction/)
    end

    it "refuses an invariant whose source could not be read" do
      expect do
        in_registry do
          Hecks.bluebook("Unreadable2") do
            aggregate("Thing") do
              value_object("V") { invariant("unreadable", &eval("proc { 1 < 2 }")) }
            end
          end
        end
      end.to raise_error(Malformed, /did not survive extraction/)
    end

    it "one_of declares a closed set of members, in declaration order" do
      registry = in_registry do
        Hecks.bluebook("Coins") do
          aggregate("Coin") do
            attribute :currency, Currency

            value_object("Currency") do
              attribute :code,        String
              attribute :minor_units, Integer

              one_of do
                member code: "USD", minor_units: 2
                member code: "JPY", minor_units: 0
              end
            end
          end
        end
      end

      currency = registry.bluebooks["Coins"].aggregates.first.value_objects.first
      expect(currency.members).to eq(
        [{ code: "USD", minor_units: 2 }, { code: "JPY", minor_units: 0 }]
      )
    end

    it "refuses an empty member" do
      expect do
        in_registry do
          Hecks.bluebook("Empty") do
            aggregate("Thing") do
              value_object("V") { one_of { member } }
            end
          end
        end
      end.to raise_error(Malformed, /empty member/)
    end

    it "desugars an inline one_of into a value object named for the attribute" do
      # Rust parsed this spelling already and threw the values away — the
      # attribute became a plain String and the closed set meant nothing. Both
      # runtimes desugar it now, identically.
      aggregate = build_aggregate("Inline") do
        attribute :status, one_of("open", "shut")
      end

      status = aggregate.attributes.find { |a| a.name == :status }
      shape  = aggregate.value_objects.find { |v| v.name == "Status" }

      expect(status.type).to eq("Status")
      expect(shape.members).to eq([{ value: "open" }, { value: "shut" }])
      expect(shape.closed_set?).to be(true)
      # enforcement is the ordinary one_of machinery from here on — the same
      # Value.admit_member path spec/one_of_spec already pins for the block form
    end

    it "refuses the scalar one_of spelling rather than dropping it" do
      expect do
        in_registry do
          Hecks.bluebook("Scalar") do
            aggregate("Thing") do
              value_object("V") { one_of }
            end
          end
        end
      end.to raise_error(Malformed, /a closed set admits a member/)
    end
  end

  describe "value-object-typed attributes" do
    def account_domain
      in_registry do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)

        Hecks.bluebook("Coerced") do
          aggregate("Holding") do
            attribute :kind,   Kind
            attribute :amount, Amount

            value_object("Kind") do
              attribute :name, String
              invariant("current or savings") { name == "current" || name == "savings" }
            end

            value_object("Amount") do
              attribute :cents,    Integer
              attribute :currency, String
            end

            command("Open") do
              attribute :kind,   Kind
              attribute :amount, Amount
            end
          end

          Hecks.hecksagon("Coerced") { Coerced::Holding.persisted_by("Memory") }
        end
      end
    end

    it "materializes a declared value object rather than a hash" do
      registry = account_domain
      runtime  = Hecksagain::Runtime::Loader.bind_runtime(
        Hecksagain::Runtime::Dispatcher.new(registry.tap(&:verify!))
      )

      state = runtime.dispatch("Coerced::Holding.Open", id: "h1", kind: { name: "current" }).state

      expect(state[:kind]).to be_a(Hecksagain::Runtime::Value)
      expect(state[:kind].type_name).to eq("Kind")
      expect(state[:kind][:name]).to eq("current")
    end

    it "identifies a value object by its declared state" do
      registry = account_domain
      runtime  = Hecksagain::Runtime::Loader.bind_runtime(
        Hecksagain::Runtime::Dispatcher.new(registry.tap(&:verify!))
      )

      first  = runtime.dispatch("Coerced::Holding.Open", id: "h1", kind: { name: "current" }).state[:kind]
      second = runtime.dispatch("Coerced::Holding.Open", id: "h2", kind: { name: "current" }).state[:kind]

      expect(first).to eq(second)
      expect(first.to_h).to eq(name: "current")
    end

    it "enforces the invariant on a value object" do
      registry = account_domain
      runtime  = Hecksagain::Runtime::Loader.bind_runtime(
        Hecksagain::Runtime::Dispatcher.new(registry.tap(&:verify!))
      )

      expect { runtime.dispatch("Coerced::Holding.Open", id: "h2", kind: { name: "offshore" }) }
        .to raise_error(Hecksagain::Runtime::InvariantViolation, /current or savings/)
    end

    it "refuses a scalar for every value object" do
      registry = account_domain
      runtime  = Hecksagain::Runtime::Loader.bind_runtime(
        Hecksagain::Runtime::Dispatcher.new(registry.tap(&:verify!))
      )

      expect { runtime.dispatch("Coerced::Holding.Open", id: "h3", kind: "current") }
        .to raise_error(Hecksagain::Runtime::TypeMismatch, /pass its fields as an object/)
    end
  end

  describe "a bluebook" do
    it "read_model declares a domain-level projection" do
      model = build_bluebook("Portfolio") do
        aggregate "Customer" do
          attribute :reference, CustomerNumber
          value_object "CustomerNumber" do
            attribute :value, String
          end
        end
        read_model "CustomerPortfolio" do
          reference_to Customer, as: :reference
          include Customer
          include Account
        end
      end.read_models.first

      expect([model.name, model.query_name, model.reference_name, model.reference_target])
        .to eq(["CustomerPortfolio", "customer_portfolio", :reference, "Customer"])
      expect(model.aggregate_heads).to eq([
        { aggregate: "Customer", as: :customer, many: false },
        { aggregate: "Account", as: :accounts, many: true }
      ])
    end

    it "gathers includes declared before the reference, in either order" do
      # `many:` is decided by comparing each include against the reference, so
      # this used to be refused. The includes are resolved at build now, which
      # removes the rule rather than moving it.
      before = build_bluebook("EitherWay") do
        read_model("Portfolio") do
          description "a portfolio"
          include Account
          reference_to Customer
        end
      end.read_models.first

      after = build_bluebook("EitherWay2") do
        read_model("Portfolio") do
          description "a portfolio"
          reference_to Customer
          include Account
        end
      end.read_models.first

      expect(before.aggregate_heads).to eq(after.aggregate_heads)
    end

    it "validates read-model reference ordering, uniqueness, and descriptions" do
      # an include with no reference at all still refuses — but for the real
      # reason, not for the order it was written in
      expect {
        build_bluebook("BadModel") do
          read_model("Portfolio") { include Customer }
        end
      }.to raise_error(Hecksagain::Bluebook::DSL::Malformed, /needs an aggregate-head reference/)

      # a reference, so `needs an aggregate-head reference` does not fire first
      # and mask the description rule this case is about
      expect {
        build_bluebook("BadModel") do
          read_model("Portfolio") do
            reference_to Customer
            description ""
          end
        end
      }.to raise_error(Hecksagain::Bluebook::DSL::Malformed, /a description says something/)

      expect {
        build_bluebook("BadModel") do
          read_model("Portfolio") do
            reference_to Customer
            reference_to Account
          end
        end
      }.to raise_error(Hecksagain::Bluebook::DSL::Malformed, /already has a projection reference/)

      expect {
        build_bluebook("BadModel") do
          read_model("Portfolio") do
            reference_to Customer
            include Customer, as: :customer
            include Customer, as: :customer
          end
        end
      }.to raise_error(Hecksagain::Bluebook::DSL::Malformed, /already projects customer/)
    end

    it "lets read models combine common query options with aggregate-head joins" do
      model = build_bluebook("QueryablePortfolio") do
        read_model "Portfolio" do
          reference_to Customer
          include Account
          where(status: "active")
          order_by :id, :desc
          limit 20
          offset 5
          cursor :after
          nulls :last
          authorize :portfolio_access, tenant: :customer_id
          consistency :snapshot
          freshness :bounded, max_age: 60
          inspect_query :sql
          use_index :customer_status
        end
      end.read_models.first

      expect(model.wheres.first.to_h).to eq(field: "status", op: "eq", value: "active")
      expect(model.aggregate_heads).to eq([{ aggregate: "Account", as: :accounts, many: true }])
      expect(model.offset.to_h).to eq(value: "5")
      expect(model.authorization.to_h).to eq(policy: "portfolio_access", tenant: "customer_id")
      expect(model.freshness.to_h).to eq(mode: "bounded", max_age: "60")
    end

    it "vision records the domain's sentence" do
      expect(build_bluebook("Visioned") { vision "sell pizza" }.vision).to eq("sell pizza")
    end

    it "policy declares a reaction the domain owns rather than one aggregate" do
      reaction = build_bluebook("Reacting") do
        policy "NotifyOnPlacement" do
          on      "OrderPlaced"
          trigger "Notify.Send"
          across  "Notifications"
        end
      end.policies.first

      expect([reaction.name, reaction.on_event, reaction.target_domain])
        .to eq(["NotifyOnPlacement", "OrderPlaced", "Notifications"])
    end

    it "process_manager declares a correlated conversation with its own states" do
      checkout = build_bluebook("Converse") do
        process_manager "Checkout" do
          correlates_by :order_id
          starts_on "OrderPlaced"
          ends_on   "OrderCompleted"
          state "awaiting_payment"
          state "paid"

          on "PaymentAuthorized", transition: { "awaiting_payment" => "paid" } do
            dispatch "Order.Confirm", with: { order: :order_id }
          end
        end
      end.process_managers.first

      expect([checkout.correlates_by, checkout.starts_on]).to eq([:order_id, "OrderPlaced"])
      expect(checkout.states).to eq(["awaiting_payment", "paid"])

      handler = checkout.handler_for("PaymentAuthorized")
      expect([handler.from_state, handler.to_state]).to eq(["awaiting_payment", "paid"])
      expect(handler.dispatches.first.to_h)
        .to eq({ command_name: "Order.Confirm", with: [["order", ":order_id"]] })
    end

    it "process_manager refuses a machine that could never advance" do
      expect do
        build_bluebook("Stateless") do
          process_manager "Broken" do
            correlates_by :id
            starts_on "Started"
            on "Next", transition: { "a" => "b" } do
              dispatch "X.Y"
            end
          end
        end
      end.to raise_error(/declares no states/)
    end

    it "process_manager refuses a transition through an undeclared state" do
      expect do
        build_bluebook("Undeclared") do
          process_manager "Broken" do
            correlates_by :id
            starts_on "Started"
            state "a"
            on "Next", transition: { "a" => "nowhere" } do
              dispatch "X.Y"
            end
          end
        end
      end.to raise_error(/never declared as a state/)
    end

    it "aggregate adds an aggregate" do
      expect(build_bluebook("Agged") { aggregate("Thing") }.aggregates.map(&:name)).to eq(["Thing"])
    end

    it "core, supporting and generic each record a classification" do
      %i[core supporting generic].each_with_index do |keyword, index|
        builder = Hecksagain::Bluebook::DSL::BluebookBuilder.new("Classified#{index}")
        builder.public_send(keyword)
        expect(builder.classification).to eq(keyword)
      end
    end

    it "verbs lists every command as a fully-qualified verb" do
      bluebook = build_bluebook("Verbed") { aggregate("Thing") { command("Do") } }
      expect(bluebook.verbs).to eq(["Verbed::Thing.Do"])
    end
  end

  describe "an aggregate" do
    it "description records what it is" do
      expect(build_aggregate("Described") { description "a thing" }.description).to eq("a thing")
    end

    it "identified_by overrides the identity attribute" do
      expect(build_aggregate("Identified") { identified_by :name }.identified_by).to eq(:name)
    end

    it "identified_by defaults to id" do
      expect(build_aggregate("Defaulted") {}.identified_by).to eq(:id)
    end

    it "lifecycle records a state machine on a field" do
      machine = build_aggregate("Machined") do
        lifecycle :status, default: "pending" do
          transition "Purchase" => "sold"
        end
      end.lifecycle

      expect([machine.field, machine.default]).to eq([:status, "pending"])
      expect(machine.target_for("Purchase")).to eq("sold")
    end

    it "lifecycle keeps a from: list as written, and flattens it only when dumped" do
      machine = build_aggregate("Guarded") do
        lifecycle :status, default: "draft" do
          transition "Archive" => "archived", from: ["sold", "draft"]
        end
      end.lifecycle

      expect(machine.transitions.size).to eq(1)
      expect(machine.transitions.first.last.from).to eq(["sold", "draft"])

      expect(machine.to_h[:transitions]).to eq([
        { command: "Archive", to_state: "archived", from_state: "sold" },
        { command: "Archive", to_state: "archived", from_state: "draft" }
      ])
    end

    it "lifecycle picks the transition whose from: admits the current state" do
      machine = build_aggregate("Progressing") do
        lifecycle :status, default: "a" do
          transition "Advance" => "b", from: "a"
          transition "Advance" => "c", from: "b"
        end
      end.lifecycle

      expect(machine.target_for("Advance", "a")).to eq("b")
      expect(machine.target_for("Advance", "b")).to eq("c")
      expect(machine.states).to eq(["a", "b", "c"])
    end

    it "entity declares an identity-bearing member inside the boundary" do
      line = build_aggregate("Ordered") do
        entity "OrderLine" do
          identified_by :sku
          attribute :sku,      Sku
          attribute :quantity, Quantity
        end
        value_object("Sku") { attribute :value, String }
        value_object("Quantity") { attribute :value, Integer }
      end.entities.first

      expect([line.name, line.identified_by]).to eq(["OrderLine", :sku])
      expect(line.attribute(:quantity).type).to eq("Quantity")
    end

    it "query records filters, ordering and a cap as DATA, never a proc" do
      found = build_aggregate("Readable") do
        query "Available" do
          where(status: "available")
          order_by :name, :desc
          limit 10
          offset 5
          cursor :after
          nulls :last
          authorize :customer_access, tenant: :account_id
          consistency :snapshot, timeout: 2
          freshness :eventual, max_age: 30
          inspect_query :sql
          use_index :status_name
        end
      end.queries.first

      expect(found.name).to eq("Available")
      expect(found.wheres.map(&:to_h)).to eq([{ field: "status", op: "eq", value: "available" }])
      expect(found.order_by.to_h).to eq({ field: "name", direction: "desc" })
      expect(found.limit.to_h).to eq({ value: "10" })
      expect(found.offset.to_h).to eq({ value: "5" })
      expect(found.cursor.to_h).to eq({ value: ":after" })
      expect(found.null_semantics.to_h).to eq({ mode: "last" })
      expect(found.authorization.to_h).to eq({ policy: "customer_access", tenant: "account_id" })
      expect(found.consistency.to_h).to eq({ mode: "snapshot", timeout: "2" })
      expect(found.freshness.to_h).to eq({ mode: "eventual", max_age: "30" })
      expect(found.inspection.to_h).to eq({ mode: "sql" })
      expect(found.index_hints.map(&:to_h)).to eq([{ name: "status_name" }])
    end

    it "query reads a comparator from the hash form" do
      found = build_aggregate("Compared") do
        query "Cheap" do
          where(price: { lt: 500 })
        end
      end.queries.first

      expect(found.wheres.first.to_h).to eq({ field: "price", op: "lt", value: "500" })
    end

    it "query refuses a comparator it does not know, rather than reading it as a literal" do
      expect do
        build_aggregate("Mistyped") do
          query "Broken" do
            where(price: { greater_than: 5 })
          end
        end
      end.to raise_error(ArgumentError, /unknown comparator/)
    end

    it "reference_to another root is an attribute, and leaves the command creating" do
      command = build_bluebook("Open") do
        aggregate("Customer") { description "A customer" }
        aggregate("Thing") { command("Do") { reference_to "Customer" } }
      end.aggregate("Thing").command("Do")

      expect(command.creates?).to be true
      expect(command.attribute(:customer_id).type).to eq("Reference<Customer>")
    end

    it "reference_to its OWN root makes the command act on an existing one" do
      command = build_command("Debit") { reference_to "Thing" }

      expect(command.creates?).to be false
      expect(command.references).to eq("Thing")
    end

    it "policy binds an event to the command it triggers" do
      reaction = build_aggregate("Reactive") do
        policy "ChargeOnPlacement" do
          on      "Order.Placed"
          trigger "Payment.Charge"
        end
      end.policies.first

      expect(reaction.on_event).to eq("Order.Placed")
      expect(reaction.trigger_command).to eq("Payment.Charge")
      expect([reaction.event_qualifier, reaction.event_name]).to eq(["Order", "Placed"])
    end

    it "attribute adds a value-object field" do
      declared = build_aggregate("Attributed") do
        value_object("Size") { attribute :value, String }
        attribute :size, Size
      end.attribute(:size)

      expect([declared.type, declared.list?, declared.scalar?]).to eq(["Size", false, true])
    end

    it "attribute takes a default" do
      aggregate = build_aggregate("Defaulting") do
        value_object("Status") { attribute :value, String }
        attribute :status, Status, default: { value: "open" }
      end
      expect(aggregate.attribute(:status).default).to eq(value: "open")
    end

    it "list_of marks an attribute as a list" do
      aggregate = build_aggregate("Listed") do
        value_object("Part") { attribute :value, String }
        attribute :parts, list_of(Part)
      end
      expect([aggregate.attribute(:parts).type, aggregate.attribute(:parts).list?]).to eq(["Part", true])
    end

    it "reference_to points at another root by its identity" do
      aggregate = build_bluebook("Referring") do
        aggregate("Pizza") { description "A pizza" }
        aggregate("Thing") { reference_to Pizza }
      end.aggregate("Thing")
      expect(aggregate.attribute(:pizza_id).type).to eq("Reference<Pizza>")
    end

    it "value_object declares a VO inside the aggregate that uses it" do
      aggregate = build_aggregate("Valued") { value_object("Part") { attribute :size, Integer } }
      expect(aggregate.value_object("Part").attribute(:size).type).to eq("Integer")
    end

    it "command declares a command" do
      expect(build_aggregate("Commanded") { command("Do") }.commands.map(&:name)).to eq(["Do"])
    end

    it "storage_name is the snake_case form used for tables and keys" do
      expect(build_aggregate("Stored") {}.storage_name).to eq("thing")
    end
  end

  describe "a value object" do
    def build_value_object(domain, &block)
      build_aggregate(domain) { value_object("Part", &block) }.value_object("Part")
    end

    it "attribute adds a field" do
      expect(build_value_object("VoAttr") { attribute :size, Integer }.attribute(:size).type).to eq("Integer")
    end

    it "list_of works inside a value object too" do
      expect(build_value_object("VoList") { attribute :tags, list_of(Tag) }.attribute(:tags).list?).to be(true)
    end

    it "invariant records the rule AND its extracted expression" do
      value_object = build_value_object("VoInv") do
        attribute :size, Integer
        invariant "size must be positive" do
          size.positive?
        end
      end
      invariant = value_object.invariants.first

      expect(invariant.description).to eq("size must be positive")
      expect(invariant.canonical).to eq("size.positive?")
    end
  end

  describe "a command" do
    it "role records who says it" do
      expect(build_command("CmdRole") { role "Chef" }.role).to eq("Chef")
    end

    it "goal records why" do
      expect(build_command("CmdGoal") { goal "feed people" }.goal).to eq("feed people")
    end

    it "attribute adds a payload field" do
      expect(build_command("CmdAttr") { attribute :size, Size }.attribute(:size).type).to eq("Size")
    end

    it "list_of works in a command payload" do
      expect(build_command("CmdList") { attribute :tags, list_of(Tag) }.attribute(:tags).list?).to be(true)
    end

    it "reference_to marks the command as acting on an existing instance" do
      command = build_command("CmdRef") { reference_to Thing }
      expect([command.references, command.creates?]).to eq(["Thing", false])
    end

    it "a command without reference_to creates" do
      expect(build_command("CmdCreate") {}.creates?).to be(true)
    end

    it "given records the guard AND its extracted expression" do
      command = build_command("CmdGiven") do
        given("must be open") { status == "open" }
      end
      given = command.givens.first

      expect(given.description).to eq("must be open")
      expect(given.canonical).to eq('status == "open"')
    end

    it "then_set to: a symbol reads a command argument" do
      mutation = build_command("CmdSetArg") { then_set :status, to: :status }.mutations.first

      expect([mutation.target, mutation.op]).to eq([:status, :set])
      expect(mutation.to_h[:source]).to eq(kind: "argument", name: "status")
    end

    it "then_set to: anything else is a literal" do
      mutation = build_command("CmdSetLit") { then_set :status, to: "sold" }.mutations.first
      expect(mutation.to_h[:source]).to eq(kind: "literal", value: "sold")
    end

    it "then_set append: pushes a built value object onto a list" do
      mutation = build_command("CmdAppend") { then_set :parts, append: { size: :size } }.mutations.first

      expect([mutation.target, mutation.op]).to eq([:parts, :append])
      expect(mutation.to_h[:fields]).to eq(size: "size")
    end

    it "then_set increment: reads a command argument to add" do
      mutation = build_command("CmdInc") { then_set :balance, increment: :amount }.mutations.first

      expect([mutation.target, mutation.op]).to eq([:balance, :increment])
      expect(mutation.to_h[:source]).to eq(kind: "argument", name: "amount")
    end

    it "then_set decrement: takes a literal amount away" do
      mutation = build_command("CmdDec") { then_set :lives, decrement: 1 }.mutations.first

      expect([mutation.target, mutation.op]).to eq([:lives, :decrement])
      expect(mutation.to_h[:source]).to eq(kind: "literal", value: 1)
    end

    it "emits announces a fact" do
      expect(build_command("CmdEmit") { emits "Done" }.emits).to eq(["Done"])
    end
  end

  describe "a port" do
    def build_port(&block)
      in_registry { Hecks.port("post", &block) }.ports["post"]
    end

    it "verb names the how-verb a bind hangs off an aggregate" do
      expect(build_port { verb "posted_by" }.verb).to eq("posted_by")
    end

    it "signal says whether the domain gets a value back or announces an event" do
      expect(build_port { signal :effect }.signal).to eq(:effect)
      expect(build_port { verb "x" }.signal).to eq(:reply)
    end

    it "reply? and effect? read the signal" do
      expect(build_port { signal :reply }.reply?).to be(true)
      expect(build_port { signal :effect }.effect?).to be(true)
    end
  end

  describe "an adapter" do
    def build_adapter(&block)
      in_registry { Hecks.adapter("Carrier", &block) }.adapters["Carrier"]
    end

    it "port declares which port it implements" do
      expect(build_adapter { port "post" }.port).to eq("post")
    end

    it "field names a config value this adapter needs" do
      expect(build_adapter { field :office }.fields).to eq([:office])
    end

    it "secret names one too, kept apart from plain fields" do
      adapter = build_adapter { secret :token }

      expect(adapter.secrets).to eq([:token])
      expect(adapter.fields).to eq([])
    end

    it "declares? answers for fields and secrets alike" do
      adapter = build_adapter do
        field  :office
        secret :token
      end

      expect(adapter.declares?(:office)).to be(true)
      expect(adapter.declares?(:token)).to be(true)
      expect(adapter.declares?(:nonsense)).to be(false)
    end

    it "an adapter needing no configuration declares nothing" do
      expect(build_adapter { port "post" }.all_fields).to eq([])
    end
  end

  describe "a world" do
    it "declares the realm and active version for this deployment" do
      registry = in_registry do
        Hecks.world("Valued") do
          realm "Acme"
          latest "v2"
        end
      end

      expect(registry.world("Valued").to_h).to include(realm: "Acme", latest: "v2")
    end

    it "any how-verb collects the values under it" do
      registry = in_registry do
        Hecks.world("Valued") do
          posted_by("Carrier") do
            office "EC1"
            attempts 3
          end
        end
      end

      expect(registry.world("Valued").for_verb("posted_by"))
        .to eq(adapter: "Carrier", office: "EC1", attempts: 3)
    end

    it "an unbound verb has no values" do
      registry = in_registry { Hecks.world("Empty") {} }
      expect(registry.world("Empty").for_verb("posted_by")).to eq({})
    end
  end

  describe "the binding proxy" do
    let(:collector) { [] }

    it ".namespace answers any aggregate constant with a proxy" do
      namespace = Hecksagain::Bluebook::DSL::BindingProxy.namespace("Dom", collector)
      expect(namespace::Anything).to be_a(Hecksagain::Bluebook::DSL::BindingProxy)
    end

    it "method_missing records a bind for any how-verb" do
      namespace = Hecksagain::Bluebook::DSL::BindingProxy.namespace("Dom", collector)
      namespace::Thing.invented_by("Someone")

      bind = collector.first
      expect([bind.aggregate, bind.verb, bind.adapter]).to eq(["Dom::Thing", "invented_by", "Someone"])
    end

    it "respond_to_missing? agrees that it answers to anything" do
      proxy = Hecksagain::Bluebook::DSL::BindingProxy.new("Dom::Thing", collector)
      expect(proxy).to respond_to(:any_verb_at_all)
    end

    it "to_s is the fully-qualified aggregate it stands for" do
      proxy = Hecksagain::Bluebook::DSL::BindingProxy.new("Dom::Thing", collector)
      expect(proxy.to_s).to eq("Dom::Thing")
    end

    it "bind_for finds the wiring for an aggregate and verb" do
      registry = in_registry { Hecks.hecksagon("Findable") { Findable::Thing.posted_by("Carrier") } }
      hexagon = registry.hecksagon("Findable")

      expect(hexagon.bind_for("Thing", "posted_by").adapter).to eq("Carrier")
      expect(hexagon.bind_for("Thing", "charged_by")).to be_nil
    end
  end

  describe "the world's settings collector" do
    it "respond_to_missing? agrees that any key is a setting" do
      collector = Hecksagain::Bluebook::DSL::SettingsCollector.new
      expect(collector).to respond_to(:anything_at_all)
    end

    it "to_h returns the collected values" do
      collector = Hecksagain::Bluebook::DSL::SettingsCollector.new
      collector.instance_eval { office "EC1" }
      expect(collector.to_h).to eq(office: "EC1")
    end
  end

  describe "the const shim" do
    it "is inert outside a load, so an ordinary typo still raises" do
      expect(Hecksagain::Bluebook::DSL::ConstShim).not_to be_active
      expect { NoSuchConstantAnywhere }.to raise_error(NameError)
    end

    it "resolves unknown constants while a load is running, and restores after" do
      seen = nil
      Hecksagain::Bluebook::DSL::ConstShim.with(->(name) { "resolved:#{name}" }) do
        seen = SomeUndefinedType
        expect(Hecksagain::Bluebook::DSL::ConstShim).to be_active
      end

      expect(seen).to eq("resolved:SomeUndefinedType")
      expect(Hecksagain::Bluebook::DSL::ConstShim).not_to be_active
    end
  end
end
