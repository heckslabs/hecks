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
  def in_registry
    registry = Hecksagain::Runtime::Registry.new
    Hecks.with_registry(registry) { yield }
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
      registry = in_registry { Hecks.family("post") { verb "posted_by" } }
      expect(registry.families["post"].verb).to eq("posted_by")
    end

    it ".adapter registers an adapter" do
      registry = in_registry { Hecks.adapter("Carrier") { family "post" } }
      expect(registry.adapters["Carrier"].family).to eq("post")
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
  describe "a bluebook" do
    it "vision records the domain's sentence" do
      expect(build_bluebook("Visioned") { vision "sell pizza" }.vision).to eq("sell pizza")
    end

    it "aggregate adds an aggregate" do
      expect(build_bluebook("Agged") { aggregate("Thing") }.aggregates.map(&:name)).to eq(["Thing"])
    end

    # Strategic classification is recorded, not enforced — it tells a reader
    # where to spend attention.
    it "core, supporting and generic each record a classification" do
      %i[core supporting generic].each_with_index do |keyword, index|
        builder = Hecksagain::Language::DSL::BluebookBuilder.new("Classified#{index}")
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
      expect(mutation.to_h[:fields]).to eq(size: :size)
    end

    it "emits announces a fact" do
      expect(build_command("CmdEmit") { emits "Done" }.emits).to eq(["Done"])
    end
  end

  # ==========================================================================
  # FamilyBuilder / AdapterBuilder — the impure boundary
  # ==========================================================================
  describe "a family" do
    def build_family(&block)
      in_registry { Hecks.family("post", &block) }.families["post"]
    end

    it "verb names the how-verb a bind hangs off an aggregate" do
      expect(build_family { verb "posted_by" }.verb).to eq("posted_by")
    end

    it "signal says whether the domain gets a value back or announces an event" do
      expect(build_family { signal :effect }.signal).to eq(:effect)
      expect(build_family { verb "x" }.signal).to eq(:reply)
    end

    it "field names a config field its adapters carry" do
      expect(build_family { field :office }.fields).to eq([:office])
    end

    # A secret is a field whose VALUE never lives in a bluebook - only the name
    # of the environment variable holding it.
    it "secret names one too" do
      expect(build_family { secret :token }.fields).to eq([:token])
    end

    it "reply? and effect? read the signal" do
      expect(build_family { signal :reply }.reply?).to be(true)
      expect(build_family { signal :effect }.effect?).to be(true)
    end
  end

  describe "an adapter" do
    # The INVERTED ARROW: the adapter declares its family, never the reverse,
    # so a new backend is purely additive.
    it "family declares which family it implements" do
      registry = in_registry { Hecks.adapter("Carrier") { family "post" } }
      expect(registry.adapters["Carrier"].family).to eq("post")
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
      namespace = Hecksagain::Language::DSL::BindingProxy.namespace("Dom", collector)
      expect(namespace::Anything).to be_a(Hecksagain::Language::DSL::BindingProxy)
    end

    # ANY how-verb is accepted, because the vocabulary belongs to the families.
    # Declaring a new family must never mean editing this class.
    it "method_missing records a bind for any how-verb" do
      namespace = Hecksagain::Language::DSL::BindingProxy.namespace("Dom", collector)
      namespace::Thing.invented_by("Someone")

      bind = collector.first
      expect([bind.aggregate, bind.verb, bind.adapter]).to eq(["Dom::Thing", "invented_by", "Someone"])
    end

    it "respond_to_missing? agrees that it answers to anything" do
      proxy = Hecksagain::Language::DSL::BindingProxy.new("Dom::Thing", collector)
      expect(proxy).to respond_to(:any_verb_at_all)
    end

    it "to_s is the fully-qualified aggregate it stands for" do
      proxy = Hecksagain::Language::DSL::BindingProxy.new("Dom::Thing", collector)
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
      collector = Hecksagain::Language::DSL::SettingsCollector.new
      expect(collector).to respond_to(:anything_at_all)
    end

    it "to_h returns the collected values" do
      collector = Hecksagain::Language::DSL::SettingsCollector.new
      collector.instance_eval { office "EC1" }
      expect(collector.to_h).to eq(office: "EC1")
    end
  end

  # ==========================================================================
  # ConstShim — what lets a bluebook name a type that does not exist yet
  # ==========================================================================
  describe "the const shim" do
    it "is inert outside a load, so an ordinary typo still raises" do
      expect(Hecksagain::Language::DSL::ConstShim).not_to be_active
      expect { NoSuchConstantAnywhere }.to raise_error(NameError)
    end

    it "resolves unknown constants while a load is running, and restores after" do
      seen = nil
      Hecksagain::Language::DSL::ConstShim.with(->(name) { "resolved:#{name}" }) do
        seen = SomeUndefinedType
        expect(Hecksagain::Language::DSL::ConstShim).to be_active
      end

      expect(seen).to eq("resolved:SomeUndefinedType")
      expect(Hecksagain::Language::DSL::ConstShim).not_to be_active
    end
  end
end
