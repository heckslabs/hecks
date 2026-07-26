# EVERY method a bluebook author can call.
#
# The DSL is the surface a domain expert actually touches, so an untested
# method here is a sentence someone can write that nothing has ever checked.
# Each example exercises ONE method and asserts what it put in the IR — not
# that it ran without raising, which is the test that always passes.
#
# When a method is added to a builder, it gets an example here in the same
# commit. The count at the bottom of this file is the whole surface.
require "hecksagain"

RSpec.describe "the DSL surface" do
  # Declarations land in whichever registry is booting, so tests supply one
  # rather than booting a whole domain from disk.
  # Extraction is loaded because reading a `given` or an `invariant` resolves
  # that port : recovering a predicate's source is an impure edge like any
  # other, and an unbound one refuses rather than silently returning empty text.
  def in_registry
    registry = Hecksagain::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      yield
    end
    registry
  end

  # Unique domain names keep the top-level constants each build installs from
  # colliding between examples.
  def build_bluebook(name, &block)
    in_registry { Hecks.bluebook(name, &block) }.bluebook(name)
  end

  def build_aggregate(domain, &block)
    build_bluebook(domain) { aggregate("Thing", &block) }.aggregate("Thing")
  end

  def build_command(domain, &block)
    build_aggregate(domain) { command("Do", &block) }.command("Do")
  end

  # ==========================================================================
  # Hecks — the module surface
  # ==========================================================================
  describe "Hecks" do
    it ".with_registry collects declarations, and restores the previous one" do
      registry = in_registry { Hecks.bluebook("WithReg") { vision "v" } }

      expect(registry.bluebook("WithReg").vision).to eq("v")
      expect(Hecksagain.current_registry).to be_nil
    end

    it ".bluebook registers a domain" do
      expect(build_bluebook("Registered").name).to eq("Registered")
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

  # ==========================================================================
  # BluebookBuilder
  # ==========================================================================
  # ==========================================================================
  # These rules were DECLARED in grammar/bluebook.bluebook and enforced by
  # nothing — a self-description executing against its own toy state while the
  # real builders accepted anything. They live in the builders now, and these
  # examples are the difference between a rule and a sentence about a rule.
  # ==========================================================================
  describe "declarations that cannot mean what they say" do
    Malformed = Hecksagain::Bluebook::DSL::Malformed

    it "refuses a vision that says nothing" do
      expect { build_bluebook("Mute") { vision "" } }
        .to raise_error(Malformed, /vision says nothing/)
    end

    it "refuses a description that says nothing" do
      expect { build_aggregate("Blank") { description "" } }
        .to raise_error(Malformed, /description says nothing/)
    end

    it "refuses an identity that names no field" do
      expect { build_aggregate("Unkeyed") { identified_by "" } }
        .to raise_error(Malformed, /names no field/)
    end

    it "refuses an unnamed attribute" do
      expect { build_aggregate("Nameless") { attribute "", String } }
        .to raise_error(Malformed, /must be named/)
    end

    it "refuses an unnamed event" do
      expect { build_command("Silent") { emits "" } }
        .to raise_error(Malformed, /unnamed event/)
    end

    it "refuses a mutation that neither sets nor appends" do
      expect { build_command("Inert") { then_set :status } }
        .to raise_error(Malformed, /neither sets nor appends/)
    end

    # A command acts on ONE root. A second SELF reference would silently win and
    # the first would still read as declared.
    it "refuses a command that names its own root twice" do
      expect do
        build_command("Confused") do
          reference_to "Thing"
          reference_to "Thing"
        end
      end.to raise_error(Malformed, /acts on ONE/)
    end

    # THE ONE THAT CLOSED HECKS'S PARITY HOLE. A predicate whose source cannot
    # be recovered is not a lenient rule — it is a rule no other runtime can
    # ever evaluate. An eval'd block has no file, so nothing to read.
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
  end

  # ==========================================================================
  # A value-object-typed SCALAR attribute is constructed and validated, not
  # stored raw. Value.build was only ever reached from the append path, so a
  # scalar declared as a value object was assigned whatever arrived — and a
  # dotted read of it answered nil, in both runtimes, over a value object that
  # never existed.
  # ==========================================================================
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

    it "lets a scalar stand in for a value object with exactly one field" do
      registry = account_domain
      runtime  = Hecksagain::Runtime::Loader.bind_runtime(
        Hecksagain::Runtime::Dispatcher.new(registry.tap(&:verify!))
      )

      state = runtime.dispatch("Coerced::Holding.Open", id: "h1", kind: "current").state

      # Constructed, so a dotted read finds the field — and the invariant ran.
      expect(state[:kind]).to eq(name: "current")
    end

    it "enforces the invariant on a coerced scalar" do
      registry = account_domain
      runtime  = Hecksagain::Runtime::Loader.bind_runtime(
        Hecksagain::Runtime::Dispatcher.new(registry.tap(&:verify!))
      )

      expect { runtime.dispatch("Coerced::Holding.Open", id: "h2", kind: "offshore") }
        .to raise_error(Hecksagain::Runtime::InvariantViolation, /current or savings/)
    end

    # Guessing which of several fields a scalar meant is how a currency ends up
    # in a cents column.
    it "refuses a scalar for a value object with more than one field" do
      registry = account_domain
      runtime  = Hecksagain::Runtime::Loader.bind_runtime(
        Hecksagain::Runtime::Dispatcher.new(registry.tap(&:verify!))
      )

      expect { runtime.dispatch("Coerced::Holding.Open", id: "h3", amount: 2500) }
        .to raise_error(Hecksagain::Runtime::TypeMismatch, /cents, currency/)
    end
  end

  describe "a bluebook" do
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
      # The :symbol KEEPS its colon — it names a value carried by the
      # correlated instance, not the literal string "order_id".
      expect(handler.dispatches.first.to_h)
        .to eq({ command_name: "Order.Confirm", with: [["order", ":order_id"]] })
    end

    # Each of these describes a machine that would LOAD and then never advance.
    # Refusing at build time is the whole reason the validations came over.
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

    # Strategic classification is recorded, not enforced — it tells a reader
    # where to spend attention.
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

  # ==========================================================================
  # AggregateBuilder
  # ==========================================================================
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

      # As authored : one transition holding both sources.
      expect(machine.transitions.size).to eq(1)
      expect(machine.transitions.first.last.from).to eq(["sold", "draft"])

      # As dumped : one record per source, which is what the interpreter reads.
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
          attribute :sku,      String
          attribute :quantity, Integer
        end
      end.entities.first

      expect([line.name, line.identified_by]).to eq(["OrderLine", :sku])
      expect(line.attribute(:quantity).type).to eq("Integer")
    end

    it "query records filters, ordering and a cap as DATA, never a proc" do
      found = build_aggregate("Readable") do
        query "Available" do
          where(status: "available")
          order_by :name, :desc
          limit 10
        end
      end.queries.first

      expect(found.name).to eq("Available")
      expect(found.wheres.map(&:to_h)).to eq([{ field: "status", op: "eq", value: "available" }])
      expect(found.order_by.to_h).to eq({ field: "name", direction: "desc" })
      expect(found.limit.to_h).to eq({ value: "10" })
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

    # THE RULE THE BANKING CORPUS FOUND. A reference to ANOTHER root is not
    # "act on an existing one" — it says which one this belongs to, and that is
    # an attribute carried by identity. Reading both alike made every
    # Account.Open refuse with "no Account with id …" : a creating command
    # asked to load the thing it was about to create.
    it "reference_to another root is an attribute, and leaves the command creating" do
      command = build_command("Open") { reference_to "Customer" }

      expect(command.creates?).to be true
      expect(command.attribute(:customer_id).type).to eq("String")
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
      # A qualified subscription names its aggregate ; the bare event survives.
      expect([reaction.event_qualifier, reaction.event_name]).to eq(["Order", "Placed"])
    end

    it "attribute adds a scalar field" do
      declared = build_aggregate("Attributed") { attribute :size, String }.attribute(:size)

      expect([declared.type, declared.list?, declared.scalar?]).to eq(["String", false, true])
    end

    it "attribute takes a default" do
      aggregate = build_aggregate("Defaulting") { attribute :status, String, default: "open" }
      expect(aggregate.attribute(:status).default).to eq("open")
    end

    # List shape is EXPLICIT. Nothing is inferred from the name.
    it "list_of marks an attribute as a list" do
      aggregate = build_aggregate("Listed") { attribute :parts, list_of(Part) }
      expect([aggregate.attribute(:parts).type, aggregate.attribute(:parts).list?]).to eq(["Part", true])
    end

    it "reference_to points at another root by its identity" do
      aggregate = build_aggregate("Referring") { reference_to Pizza }
      expect(aggregate.attribute(:pizza_id).type).to eq("String")
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

  # ==========================================================================
  # ValueObjectBuilder
  # ==========================================================================
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

  # ==========================================================================
  # CommandBuilder
  # ==========================================================================
  describe "a command" do
    it "role records who says it" do
      expect(build_command("CmdRole") { role "Chef" }.role).to eq("Chef")
    end

    it "goal records why" do
      expect(build_command("CmdGoal") { goal "feed people" }.goal).to eq("feed people")
    end

    it "attribute adds a payload field" do
      expect(build_command("CmdAttr") { attribute :size, Integer }.attribute(:size).type).to eq("Integer")
    end

    it "list_of works in a command payload" do
      expect(build_command("CmdList") { attribute :tags, list_of(Tag) }.attribute(:tags).list?).to be(true)
    end

    # reference_to is what separates an update from a create — there is no
    # separate create keyword.
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
      # An appended field says WHICH it is : a :symbol renders as the bare
      # argument name, a String literal keeps its quotes. Rendering both alike
      # would make `{ direction: :direction }` and `{ direction: "direction" }`
      # the same document.
      expect(mutation.to_h[:fields]).to eq(size: "size")
    end

    it "emits announces a fact" do
      expect(build_command("CmdEmit") { emits "Done" }.emits).to eq(["Done"])
    end
  end

  # ==========================================================================
  # PortBuilder / AdapterBuilder — the impure boundary
  # ==========================================================================
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

    # The INVERTED ARROW: the adapter declares its family, never the reverse,
    # so a new backend is purely additive.
    it "port declares which port it implements" do
      expect(build_adapter { port "post" }.port).to eq("post")
    end

    # Fields belong to the ADAPTER, not the family. Adapters in one family
    # genuinely differ - Sqlite needs a database, Memory nothing - and a field
    # list on the family would force one shape onto both.
    it "field names a config value this adapter needs" do
      expect(build_adapter { field :office }.fields).to eq([:office])
    end

    # A secret is a field whose VALUE never lives in a bluebook - only the name
    # of the environment variable holding it.
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

  # ==========================================================================
  # WorldBuilder — values, never wiring
  # ==========================================================================
  describe "a world" do
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

  # ==========================================================================
  # BindingProxy — what makes Pizzas::Pizza.persisted_by("Sqlite") legal
  # before Pizzas::Pizza is a real class
  # ==========================================================================
  describe "the binding proxy" do
    let(:collector) { [] }

    it ".namespace answers any aggregate constant with a proxy" do
      namespace = Hecksagain::Bluebook::DSL::BindingProxy.namespace("Dom", collector)
      expect(namespace::Anything).to be_a(Hecksagain::Bluebook::DSL::BindingProxy)
    end

    # ANY how-verb is accepted, because the vocabulary belongs to the families.
    # Declaring a new family must never mean editing this class.
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

  # ==========================================================================
  # ConstShim — what lets a bluebook name a type that does not exist yet
  # ==========================================================================
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
