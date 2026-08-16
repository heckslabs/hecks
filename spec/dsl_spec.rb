require "hecksagain"
require_relative "support/postgres_probe"

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

  # A BASELINE IDENTITY, so tests exercising something else entirely — a
  # lifecycle, a query, a default — do not each have to declare one to pass
  # MetaValidator's "an aggregate says what it is known by" (Seal never
  # defaults this any more ; see the `identified_by` tests below, which are
  # what actually exercises the rule). A block that declares its OWN
  # `identified_by` overrides this one, since it runs after and the builder
  # keeps only the last call.
  def build_aggregate(domain, &block)
    build_bluebook(domain) do
      aggregate("Thing") do
        identified_by :thing_id
        instance_eval(&block) if block
      end
    end.aggregate("Thing")
  end

  def build_command(domain, &block)
    build_aggregate(domain) do
      value_object("Size") { attribute :value, Integer }
      value_object("Tag") { attribute :value, String }

      # The fields the sets cases below mutate. A mutation must name a field
      # the aggregate declares (AggregateBuilder#seal_mutation_targets), so the
      # fixture declares them instead of mutating into a void — which is what it
      # used to do, silently, while asserting the mutation had been recorded.
      attribute :status,  Tag
      attribute :balance, Size
      attribute :lives,   Size
      attribute :parts,   list_of(Size)

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

    it ".hecksagon registers a domain-level default bind, applied to every aggregate that doesn't override it" do
      registry = in_registry do
        Hecks.hecksagon("Hexed") do
          posted_by "Carrier"
          Hexed::Thing.posted_by("SpecialCarrier")
        end
      end
      hexagon = registry.hecksagon("Hexed")

      default_bind = hexagon.binds.find { |b| b.aggregate.nil? }
      expect([default_bind.aggregate, default_bind.verb, default_bind.adapter])
        .to eq([nil, "posted_by", "Carrier"])

      # An aggregate-specific bind still wins over the domain default.
      expect(hexagon.bind_for("Thing", "posted_by").adapter).to eq("SpecialCarrier")
      # An aggregate with no bind of its own falls back to the default.
      expect(hexagon.bind_for("OtherThing", "posted_by").adapter).to eq("Carrier")
    end

    it ".hecksagon registers subscriptions, taken from outside the domain's own bluebook" do
      registry = in_registry do
        Hecks.hecksagon("Hexed") do
          Hexed::Thing.posted_by("Carrier")
          subscribe "OutsideEventHappened"
          subscribe "AnotherOutsideEvent"
        end
      end

      expect(registry.hecksagon("Hexed").subscriptions)
        .to eq(["OutsideEventHappened", "AnotherOutsideEvent"])
    end

    it ".hecksagon's uses_framework loads a framework member into the same registry" do
      registry = in_registry do
        Hecks.hecksagon("Hexed") do
          uses_framework "Governance"
          Hexed::Thing.posted_by("Carrier")
        end
      end

      expect(registry.bluebook("Governance")).not_to be_nil
      expect(registry.bluebook("Governance").aggregate("RoleAssignment")).not_to be_nil
      expect(registry.hecksagon("Hexed").framework_members).to eq(["Governance"])
    end

    it ".data_translation registers a rename, a move, a convert, and a drop between two eras" do
      registry = in_registry do
        Hecks.data_translation("Translated", from: "1", to: "2") do
          aggregate("Thing", was: "Widget") do
            rename :cost, to: :amount
            move "price.cents", to: "price_cents"
            convert "kind.label", to: "kind.label", values: { "old" => "new" }
            drop :legacy_note
          end
        end
      end
      translation = registry.translations.first
      thing = translation.for_aggregate("Thing")

      expect([translation.domain, translation.from, translation.to]).to eq(["Translated", "1", "2"])
      expect([thing.was, thing.renames]).to eq(["Widget", { cost: :amount }])
      expect(thing.moves.map { |move| [move.from, move.to] }).to eq([["price.cents", "price_cents"]])
      expect(thing.converts.map { |c| [c.from, c.to, c.values] }).to eq([["kind.label", "kind.label", { "old" => "new" }]])
      expect(thing.drops).to eq([:legacy_note])
    end

    it ".data_translation registers a retype and a retired aggregate" do
      registry = in_registry do
        Hecks.data_translation("Translated", from: "1", to: "2") do
          aggregate("Thing") { retype "Money", to: "Cash" }
          retired "Ledger"
        end
      end
      translation = registry.translations.first

      expect(translation.for_aggregate("Thing").retypes.map { |r| [r.from, r.to] }).to eq([["Money", "Cash"]])
      expect(translation.retired).to eq(["Ledger"])
    end

    it ".data_translation registers a compute with its SQL expression" do
      registry = in_registry do
        Hecks.data_translation("Translated", from: "1", to: "2") do
          aggregate("Thing") { compute "price_cents", to: "price_dollars", sql: "price_cents::numeric / 100" }
        end
      end
      computed = registry.translations.first.for_aggregate("Thing").computes.first

      expect([computed.from, computed.to, computed.sql])
        .to eq(["price_cents", "price_dollars", "price_cents::numeric / 100"])
    end

    it ".data_translation registers a rekey with its SQL expression" do
      registry = in_registry do
        Hecks.data_translation("Translated", from: "1", to: "2") do
          aggregate("Thing") { rekey sql: "(__s ->> 'email')" }
        end
      end
      rekeyed = registry.translations.first.for_aggregate("Thing").rekeys.first

      expect(rekeyed.sql).to eq("(__s ->> 'email')")
    end

    it ".data_translation refuses a rekey with no sql:" do
      expect do
        in_registry do
          Hecks.data_translation("Translated", from: "1", to: "2") do
            aggregate("Thing") { rekey sql: "" }
          end
        end
      end.to raise_error(Hecksagain::Bluebook::DSL::Malformed, /needs its sql: expression/)
    end

    it ".data_translation registers a backfill with its default value" do
      registry = in_registry do
        Hecks.data_translation("Translated", from: "1", to: "2") do
          aggregate("Thing") { backfill :tier, default: "standard" }
        end
      end
      backfilled = registry.translations.first.for_aggregate("Thing").backfills.first

      expect([backfilled.name, backfilled.default]).to eq([:tier, "standard"])
    end

    it ".data_translation refuses a backfill with no default:" do
      expect do
        in_registry do
          Hecks.data_translation("Translated", from: "1", to: "2") do
            aggregate("Thing") { backfill :tier, default: nil }
          end
        end
      end.to raise_error(Hecksagain::Bluebook::DSL::Malformed, /needs a default: value/)
    end

    it ".data_translation refuses an unresolved placeholder and an unknown rule" do
      expect do
        in_registry do
          Hecks.data_translation("Translated", from: "1", to: "2") do
            aggregate("Thing") { unresolved :cost, candidates: [:amount] }
          end
        end
      end.to raise_error(Hecksagain::Bluebook::DSL::Malformed, /leaves :cost unresolved/)

      expect do
        in_registry do
          Hecks.data_translation("Translated", from: "1", to: "2") do
            aggregate("Thing") { renmae :cost, to: :amount }
          end
        end
      end.to raise_error(Hecksagain::Bluebook::DSL::Malformed, /got 'renmae'/)

      expect do
        in_registry do
          Hecks.data_translation("Translated", from: "1", to: "2") { banana "Thing" }
        end
      end.to raise_error(Hecksagain::Bluebook::DSL::Malformed, /does not understand 'banana'/)
    end

    # A real `Hecks.boot`, not `boot_in_memory` — examples/pizzas' own
    # .world declares `persisted_by("PostgresEra")` unconditionally (see
    # support/postgres_probe.rb's own note on why that probe exists), so
    # this genuinely needs a reachable Postgres carrying the hecks_pizzas
    # database — same as every other real-Postgres spec, `io: true` and
    # self-skipping otherwise.
    it ".boot loads a domain directory and returns the door",
       io: true do
      skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

      runtime = Hecks.boot(File.expand_path("../examples/pizzas", __dir__))
      expect(runtime).to be_a(Hecksagain::Runtime::Dispatcher)
      expect(runtime.verbs).to include("Pizzas::Order.Purchase")
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

    it "refuses an identity with no block at all" do
      expect { build_aggregate("Unkeyed") { identified_by } }
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

    # WHAT IT IS KNOWN BY, not "id". A ValueObject is known by its aggregate AND
    # its name — `identified_by do aggregate_id ; name.value end` — and this said
    # `id`, a field the category does not have, because the refusal read
    # `identified_by`, which is the SINGLE head and goes nil the moment an
    # identity has two parts. The quoted id was always the JOIN of those two
    # ("Primitive:Thing" and "String"); now the message says so.
    it "refuses an aggregate attribute that is not a value object" do
      expect { build_aggregate("Primitive") { attribute :code, String } }
        .to raise_error(Malformed, %r{no ValueObject with aggregate, name "Primitive:Thing:String"})
    end

    # A PIECE IS REACHED THROUGH ITS AGGREGATE, so a command on one addresses
    # the aggregate and never the piece. This used to be described as "a
    # reference to an entity rather than an aggregate head", which is not what
    # it checks: `CommandBuilder#reference_to` only sets `references` when the
    # target names the OWNER, so the only thing that can reach here is a piece's
    # command naming itself.
    it "refuses an entity command that names itself as its root" do
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
      end.to raise_error(Malformed,
                         "an entity command is addressed through its aggregate; " \
                         "Root.Child.Change names itself as its root")
    end

    # REFUSED BY THE LANGUAGE NOW, not by a raise beside the builder. A
    # command's reference argument is offered to the meta-domain as the head's
    # own id, so "points at a declared head" is what reference resolution
    # already means — no predicate, and a message that says which id it looked
    # for and failed to find.
    it "refuses a reference to a value object rather than an aggregate head" do
      expect do
        build_bluebook("HeadOnly") do
          aggregate "Root" do
            identified_by :id

            value_object("Code") { attribute :value, String }

            command("UseCode") { reference_to Code }
          end
        end
      end.to raise_error(Malformed,
                         /UseCode#attributes\[0\]: no Aggregate with bluebook, name "HeadOnly:Code"/)
    end

    # A DEFAULT FILLS THE SHAPE IT IS DECLARED ON. `default: "open"` on a
    # value-object attribute built cleanly and then refused every create at
    # dispatch, which cost a corpus member 33 refusals out of 40 steps while
    # every downstream check still passed — refusing consistently is
    # agreement about nothing.
    it "refuses a bare default where the type wants fields" do
      expect do
        build_aggregate("Defaulted") do
          value_object("Cover") { attribute :value, String }
          attribute :cover, Cover, default: "open"
        end
      end.to raise_error(Malformed, /Cover is a value object — a default fills its FIELDS/)
    end

    it "takes a default that fills the fields" do
      thing = build_aggregate("Defaulted") do
        value_object("Cover") { attribute :value, String }
        attribute :cover, Cover, default: { value: "open" }
      end

      expect(thing.attribute(:cover).default).to eq({ value: "open" })
    end

    it "refuses an unnamed event" do
      expect { build_command("Silent") { emits "" } }
        .to raise_error(Malformed, /an event is named/)
    end

    it "carries an ensures as canonical text beside the givens" do
      # The postcondition rides the same Rule shape preconditions do —
      # extracted, canonicalised, serialized — and `old` is just a word
      # in the text until enforcement resolves it.
      spelled = build_command("Ensured") do
        ensures("it landed") { old.balance.cents <= balance.cents }
      end

      expect(spelled.ensures.map(&:canonical)).to eq(["old.balance.cents <= balance.cents"])
      expect(spelled.to_h[:ensures]).to eq([{ description: "it landed",
                                              canonical: "old.balance.cents <= balance.cents" }])
    end

    it "sets alone, with no operation named at all, means to: the same field — the omittable case" do
      # `to:` is omittable when it would only repeat the target (ADR 0025) —
      # `sets :status` alone means exactly `sets :status, to: :status`.
      mutation = build_command("Bare") { sets :status }.mutations.first

      expect([mutation.target, mutation.op]).to eq([:status, :set])
      expect(mutation.to_h[:source]).to eq(kind: "argument", name: "status")
    end

    it "refuses the redundant explicit spelling — sets :field, to: :field says nothing sets :field doesn't" do
      expect { build_command("Redundant") { sets :status, to: :status } }
        .to raise_error(Malformed, /repeats the target/)
    end

    it "then_set is gone — sets is the word now (ADR 0025 reverts the rename)" do
      # `sets` is the word; `then_set` was the era every existing bluebook was
      # written under (Syntax::Keyword still carries it as `was:`) — reachable
      # only for frozen era text under EraGuard.shadow_parse now, the same
      # bridge S2's has_* removal used.
      expect { build_command("Spelled2") { then_set :balance, increment: :amount } }
        .to raise_error(Malformed, "Do's then_set is gone — sets is the word now")
    end

    it "refuses a mutation that names two operations" do
      expect { build_command("Torn") { sets :balance, to: 5, increment: :amount } }
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

    it "refuses a command that declares role twice" do
      expect do
        build_command("DoubleRole") do
          role "Teller"
          role "Branch manager"
        end
      end.to raise_error(Malformed, /role twice/)
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

    it "bare member lines declare a closed set of members, in declaration order" do
      registry = in_registry do
        Hecks.bluebook("Coins") do
          aggregate("Coin") do
            identified_by :id

            attribute :currency, Currency

            value_object("Currency") do
              attribute :code,        String
              attribute :minor_units, Integer

              member code: "USD", minor_units: 2
              member code: "JPY", minor_units: 0
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
              value_object("V") { member }
            end
          end
        end
      end.to raise_error(Malformed, /empty member/)
    end

    it "desugars an inline one_of into a value object named for the attribute" do
      # An earlier reader parsed this spelling and threw the values away — the
      # attribute became a plain String and the closed set meant nothing. The
      # desugaring here keeps the set closed.
      aggregate = build_aggregate("Inline") do
        attribute :status, one_of("open", "shut")
      end

      status = aggregate.attributes.find { |a| a.name == :status }
      shape  = aggregate.value_object("Status")

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
      end.to raise_error(Malformed, /names no values/)
    end
  end

  describe "value-object-typed attributes" do
    def account_domain
      in_registry do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)

        Hecks.bluebook("Coerced") do
          aggregate("Holding") do
            # THE ID EVERY TEST BELOW ALREADY PASSES ("h1", "h2"...) IS THE FACT.
            # A bare scalar payload short-circuits the ".value" dig (see
            # `identity_from`'s "AN ID IS ALWAYS A SCALAR" note), so this derives
            # from exactly what each dispatch already supplies — nothing minted.
            identified_by :id

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

      state = runtime.dispatch("Coerced::Holding.Open", id: "h1",
                               kind: { name: "current" }, amount: { cents: 100, currency: "GBP" }).state

      expect(state[:kind]).to be_a(Hecksagain::Runtime::Value)
      expect(state[:kind].type_name).to eq("Kind")
      expect(state[:kind][:name]).to eq("current")
    end

    it "identifies a value object by its declared state" do
      registry = account_domain
      runtime  = Hecksagain::Runtime::Loader.bind_runtime(
        Hecksagain::Runtime::Dispatcher.new(registry.tap(&:verify!))
      )

      first  = runtime.dispatch("Coerced::Holding.Open", id: "h1",
                                kind: { name: "current" }, amount: { cents: 100, currency: "GBP" }).state[:kind]
      second = runtime.dispatch("Coerced::Holding.Open", id: "h2",
                                kind: { name: "current" }, amount: { cents: 250, currency: "GBP" }).state[:kind]

      expect(first).to eq(second)
      expect(first.to_h).to eq(name: "current")
    end

    it "enforces the invariant on a value object" do
      registry = account_domain
      runtime  = Hecksagain::Runtime::Loader.bind_runtime(
        Hecksagain::Runtime::Dispatcher.new(registry.tap(&:verify!))
      )

      expect {
        runtime.dispatch("Coerced::Holding.Open", id: "h2",
                         kind: { name: "offshore" }, amount: { cents: 100, currency: "GBP" })
      }
        .to raise_error(Hecksagain::Runtime::InvariantViolation, /current or savings/)
    end

    # NOT for every value object any more. `Value::Coercion#fields_for` was
    # deliberately widened (migration plan task 5, this split's own item 17)
    # to auto-wrap a bare scalar into a SINGLE-field value object's sole
    # attribute — `Kind` here has exactly one field, so `kind: "current"`
    # now auto-wraps to `{ name: "current" }` rather than refusing. The
    # refusal survives only for a genuinely MULTI-field value object, where
    # the scalar cannot say which field it means — `Amount` (cents +
    # currency) is that case here.
    it "refuses a scalar for every multi-field value object" do
      registry = account_domain
      runtime  = Hecksagain::Runtime::Loader.bind_runtime(
        Hecksagain::Runtime::Dispatcher.new(registry.tap(&:verify!))
      )

      expect {
        runtime.dispatch("Coerced::Holding.Open", id: "h3",
                         kind: { name: "current" }, amount: "a lot")
      }
        .to raise_error(Hecksagain::Runtime::TypeMismatch, /pass its fields as an object/)
    end
  end

  describe "a bluebook" do
    it "read_model declares a domain-level projection" do
      model = build_bluebook("Portfolio") do
        aggregate "Customer" do
          identified_by :id

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

    it "report is gone — read_model is the word now (ADR 0025 reverts the rename)" do
      expect do
        build_bluebook("ReportGone") do
          aggregate "Customer" do
            identified_by :id

            attribute :reference, CustomerNumber
            value_object "CustomerNumber" do
              attribute :value, String
            end
          end
          report("CustomerPortfolio") { reference_to Customer, as: :reference }
        end
      end.to raise_error(Malformed, "report is gone — read_model is the word now")
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
      # An include with no reference at all is now a ROOTLESS read model —
      # a bulk view of its own included head(s), no root record required —
      # and succeeds rather than refusing.
      expect {
        build_bluebook("BadModel") do
          read_model("Portfolio") { include Customer }
        end
      }.not_to raise_error

      # A read model naming NEITHER a reference NOR any include has nothing
      # to describe at all — the one case that still refuses.
      expect {
        build_bluebook("BadModel") do
          read_model("Portfolio") { description "nothing to gather" }
        end
      }.to raise_error(Hecksagain::Bluebook::DSL::Malformed, /needs an aggregate-head reference or at least one include/)

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
          nulls :last
          authorize :portfolio_access, tenant: :customer_id
          inspect_query :sql
        end
      end.read_models.first

      expect(model.wheres.first.to_h).to eq(field: "status", op: "eq", value: %q("active"))
      expect(model.aggregate_heads).to eq([{ aggregate: "Account", as: :accounts, many: true }])
      expect(model.offset.to_h).to eq(value: "5")
      expect(model.authorization.to_h).to eq(policy: "portfolio_access", tenant: "customer_id")
    end

    it "read_model refuses cursor at build — no interpreter implements cursor pagination" do
      expect {
        build_bluebook("CursoredPortfolio") do
          read_model "Portfolio" do
            reference_to Customer
            include Account
            cursor :after
          end
        end
      }.to raise_error(Hecksagain::Bluebook::DSL::Malformed, /declares cursor, but no interpreter implements cursor pagination/)
    end

    it "refuses two aggregates that reference each other" do
      expect {
        build_bluebook("BackAndForth") do
          aggregate "Rider" do
            identified_by :tag
            attribute :tag, RiderTag
            value_object "RiderTag" do
              attribute :value, String
            end
            reference_to Bicycle
          end

          aggregate "Bicycle" do
            identified_by :serial
            attribute :serial, BicycleSerial
            value_object "BicycleSerial" do
              attribute :value, String
            end
            reference_to Rider
          end
        end
      }.to raise_error(Hecksagain::Bluebook::DSL::Malformed, /reference cycle: (Rider -> Bicycle -> Rider|Bicycle -> Rider -> Bicycle)/)
    end

    # S9, ADR 0025 — an OWNED PIECE's own reference_to used to feed no
    # edge into this same check at all (only AggregateBuilder#reference_to
    # ever populated @reference_targets), so a ring closing through a
    # contained entity built cleanly, invisibly, the same shape this
    # check already refuses when the ring is direct.
    it "refuses a reference cycle that closes through an owned entity" do
      expect {
        build_bluebook("BackAndForthThroughAPiece") do
          aggregate "Board" do
            identified_by :tag
            attribute :tag, BoardTag
            value_object "BoardTag" do
              attribute :value, String
            end

            entity "Card" do
              identified_by :sequence
              attribute :sequence, Integer
              reference_to Product
            end
          end

          aggregate "Product" do
            identified_by :sku
            attribute :sku, ProductSku
            value_object "ProductSku" do
              attribute :value, String
            end
            reference_to Board
          end
        end
      }.to raise_error(Hecksagain::Bluebook::DSL::Malformed,
                        /reference cycle: (Board -> Product -> Board|Product -> Board -> Product)/)
    end

    it "allows one aggregate to reference another in a single direction" do
      bluebook = build_bluebook("OneWay") do
        aggregate "Owner" do
          identified_by :tag
          attribute :tag, OwnerTag
          value_object "OwnerTag" do
            attribute :value, String
          end
        end

        aggregate "Item" do
          identified_by :serial
          attribute :serial, ItemSerial
          value_object "ItemSerial" do
            attribute :value, String
          end
          reference_to Owner
        end
      end

      expect(bluebook.aggregate("Item").reference_targets).to eq(["Owner"])
    end

    it "vision records the domain's sentence" do
      expect(build_bluebook("Visioned") { vision "sell pizza" }.vision).to eq("sell pizza")
    end

    it "formerly_known_as records what a domain's own identity used to be" do
      expect(build_bluebook("Renamed") { formerly_known_as "OldName" }.formerly_known_as).to eq("OldName")
    end

    it "policy declares a reaction the domain owns rather than one aggregate" do
      reaction = build_bluebook("Reacting") do
        policy "NotifyOnPlacement" do
          on      "OrderPlaced"
          trigger Notify::Send
          across  "Notifications"
        end
      end.policies.first

      expect([reaction.name, reaction.on_event, reaction.target_domain])
        .to eq(["NotifyOnPlacement", "OrderPlaced", "Notifications"])
    end

    it "process_manager declares a correlated conversation with states DERIVED from its own transitions" do
      checkout = build_bluebook("Converse") do
        process_manager "Checkout" do
          correlates_by :"order.id"
          starts_on "OrderPlaced"
          ends_on   "OrderCompleted"

          transition "PaymentAuthorized" => "paid", from: "awaiting_payment" do
            dispatch Order::Confirm, with: { order: :order_id }
          end
        end
      end.process_managers.first

      expect([checkout.correlates_by, checkout.starts_on]).to eq([:"order.id", "OrderPlaced"])
      # DERIVED (S7), not declared — no `state "x"` lines exist any more;
      # every state a transition names IS a state this procedure has,
      # first-seen order, the same reading Behaviour::Lifecycle#states
      # already gives an aggregate's own field.
      expect(checkout.states).to eq(["awaiting_payment", "paid"])

      handler = checkout.handler_for("PaymentAuthorized")
      expect([handler.from_state, handler.to_state]).to eq(["awaiting_payment", "paid"])
      expect(handler.dispatches.first.to_h)
        .to eq({ command_name: "Order.Confirm", with_spec: [["order", ":order_id"]] })
    end

    it "process_manager refuses a machine with no transitions at all" do
      expect do
        build_bluebook("Stateless") do
          process_manager "Broken" do
            correlates_by :"id.value"
            starts_on "Started"
          end
        end
      end.to raise_error(/declares no transitions/)
    end

    # S7, ADR 0025 — ONE STATE-MACHINE VOCABULARY: states are DERIVED
    # from the transitions that name them now, so "a transition through
    # an undeclared state" is no longer a mistake a bluebook CAN make —
    # every from:/to: a transition names automatically becomes a state
    # this procedure has, by construction. What replaces it: a
    # transition naming no from: at all, which `advance_saga`'s own
    # plain-equality admission check would never match — refused here
    # instead of building a handler nothing could ever reach.
    it "process_manager refuses a transition naming no from: — it would match no instance ever" do
      expect do
        build_bluebook("Unguarded") do
          process_manager "Broken" do
            correlates_by :"id.value"
            starts_on "Started"
            transition "Next" => "b" do
              dispatch X::Y
            end
          end
        end
      end.to raise_error(/names no from:/)
    end

    it "process_manager refuses correlates_by that resolves to a value object, not a scalar" do
      # ProcessManagerBuilder#validate! only knows the spelling has a dot ;
      # the whole-document check knows what that dot actually reaches.
      # `ref.amount` is a real field on a real value object — `Ref` genuinely
      # declares `amount` — but `amount`'s own type, `Amount`, is ANOTHER
      # value object, not a scalar. The dot ran out one VO short of a real
      # field, the same class of mistake `identified_by` already refuses on
      # the aggregate side.
      expect do
        build_bluebook("NonScalarKey") do
          aggregate "Thing" do
            identified_by :id
            attribute :id, ThingId

            value_object "ThingId" do
              attribute :value, String
            end

            value_object "Ref" do
              attribute :amount, Amount
            end

            value_object "Amount" do
              attribute :cents, Integer
            end

            command "Start" do
              attribute :id,  ThingId
              attribute :ref, Ref
              emits "Started"
            end
          end

          process_manager "Broken" do
            correlates_by :"ref.amount"
            starts_on "Started"
            transition "Started" => "b", from: "a" do
              dispatch Thing::Start
            end
          end
        end
      end.to raise_error(/Amount is a value object, not a scalar/)
    end

    it "process_manager refuses correlates_by naming a field no emitting command declares that shape for" do
      expect do
        build_bluebook("StrandedKey") do
          aggregate "Thing" do
            identified_by :id
            attribute :id, ThingId

            value_object "ThingId" do
              attribute :value, String
            end

            value_object "Ref" do
              attribute :amount, Amount
            end

            value_object "Amount" do
              attribute :cents, Integer
            end

            command "Start" do
              attribute :id,  ThingId
              attribute :ref, Ref
              emits "Started"
            end
          end

          process_manager "Broken" do
            correlates_by :"ref.currency"
            starts_on "Started"
            transition "Started" => "b", from: "a" do
              dispatch Thing::Start
            end
          end
        end
      end.to raise_error(/Ref has no field "currency"/)
    end

    it "aggregate adds an aggregate" do
      # `identified_by` reads its OWN source line via Prism, so it needs a line to
      # itself — stacking it on the SAME line as the block that opens it makes
      # `block_node_at` find that OUTER block first (walk is pre-order) and read
      # the wrong source entirely.
      built = build_bluebook("Agged") do
        aggregate("Thing") do
          identified_by :id
        end
      end
      expect(built.aggregates.map(&:name)).to eq(["Thing"])
    end

    it "core, supporting and generic each record a classification" do
      %i[core supporting generic].each_with_index do |keyword, index|
        builder = Hecksagain::Bluebook::DSL::BluebookBuilder.new("Classified#{index}")
        builder.public_send(keyword)
        expect(builder.classification).to eq(keyword)
      end
    end

    it "verbs lists every command as a fully-qualified verb" do
      bluebook = build_bluebook("Verbed") do
        aggregate("Thing") do
          identified_by :id
          command("Do")
        end
      end
      expect(bluebook.verbs).to eq(["Verbed::Thing.Do"])
    end

    # An entity-owned command reaches Runtime::Dispatcher#dispatch through
    # the same dotted-verb routing (command_name.include?(".")) an
    # ordinary command never uses — so it was always real and dispatchable,
    # just missing from this list. Two levels deep, not one, because S17
    # (ADR 0026) made entities nest inside entities for real (Dispatch,
    # inside Handler) — a fix that only walked one level would still miss
    # the deepest verb.
    it "verbs recurses into entities, arbitrarily deep, as dotted verbs" do
      bluebook = build_bluebook("Nested") do
        aggregate("Thing") do
          identified_by :id
          command("Do")

          entity("Piece") do
            identified_by :piece_id
            command("Advance")

            entity("SubPiece") do
              identified_by :sub_id
              command("Touch")
            end
          end
        end
      end

      expect(bluebook.verbs).to contain_exactly(
        "Nested::Thing.Do",
        "Nested::Thing.Piece.Advance",
        "Nested::Thing.Piece.SubPiece.Touch"
      )
    end
  end

  describe "an aggregate" do
    it "description records what it is" do
      expect(build_aggregate("Described") { description "a thing" }.description).to eq("a thing")
    end

    it "provenance records where a concept came from, as a literal Hash" do
      origin = { source: "HecksCanonical", source_id: "aggregate:thing", source_version: "1.0" }
      provenanced = build_aggregate("Provenanced") { provenance from: origin }

      expect(provenanced.provenance).to eq(origin)
    end

    it "identified_by names a field, and the HEAD is what readers look up" do
      identified = build_aggregate("Identified") do
        value_object("IdentifiedName") { attribute :value, String }
        attribute :name, IdentifiedName

        identified_by :name
      end

      expect(identified.identity_paths).to eq(["name.value"])
      expect(identified.identified_by).to eq(:name)
    end

    it "identified_by joins several paths, and offers no single HEAD for a composite" do
      identified = build_aggregate("Composite") do
        value_object("CompositeName") { attribute :value, String }
        attribute :name, CompositeName

        # `:batch_id` — no matching attribute, resolved bare by the same
        # `_id`-convention `resolve_identity_field!` already grants a
        # reference (see that method's own comment); `:name` unwraps
        # its single-field value object the ordinary way.
        identified_by :batch_id, :name
      end

      expect(identified.identity_paths).to eq(["batch_id", "name.value"])
      expect(identified.identity_heads).to eq([:batch_id, :name])
      expect(identified.identified_by).to be_nil
    end

    # NOTHING IS MINTED, so nothing DEFAULTS either — a default WAS a mint, just
    # a lazier one. An aggregate that declares no identity has none : it cannot
    # be created (hydrate's creating branch has nothing to derive from) until it
    # says what it is known by.
    #
    # Built through the RAW builder, not `build_aggregate` : that helper hands
    # every fixture a baseline identity so the OTHER 40 tests in this file
    # don't have to think about one, which makes it the wrong tool for proving
    # there is no default underneath.
    it "identified_by has no default : an aggregate that declares none has none" do
      undeclared = Hecksagain::Bluebook::DSL::AggregateBuilder.build("Undeclared") {}

      expect(undeclared.identity_paths).to eq([])
      expect(undeclared.identified_by).to be_nil
    end

    describe "identified_by :field — deriving the path from a single-field value object" do
      it "derives the same path { field.value } would have written by hand" do
        identified = build_aggregate("Community") do
          identified_by :id
          value_object("CommunityId") { attribute :value, String }
          attribute :id, CommunityId
        end

        expect(identified.identity_paths).to eq(["id.value"])
        expect(identified.identified_by).to eq(:id)
      end

      it "refuses a value object with more than one field, naming every candidate" do
        expect do
          build_aggregate("Thing") do
            identified_by :ref
            value_object("ThingRef") do
              attribute :value, String
              attribute :pad, Integer
            end
            attribute :ref, ThingRef
          end
        end.to raise_error(Malformed, /identified_by :ref names ThingRef, which has 2 fields \(value, pad\)/)
      end

      it "refuses a field the aggregate never declares" do
        expect do
          build_aggregate("Thing") { identified_by :nonexistent }
        end.to raise_error(Malformed, /identified_by :nonexistent names no attribute Thing declares/)
      end

      # ADR 0025, "References": an identity head may be a single-field
      # value object, a bare scalar, OR A REFERENCE — a reference is
      # already a scalar id the moment it is stored (`reference_to`
      # mints a bare attribute, never a nested object), so there is
      # nothing to unwrap and it resolves to its own name unchanged.
      # This used to refuse; ADR 0025 admits it on purpose.
      it "admits a reference — already a scalar, nothing to derive" do
        bluebook = build_bluebook("Refs") do
          aggregate "Team" do
            identified_by :name
            value_object("Name") { attribute :value, String }
            attribute :name, Name
          end

          aggregate "Board" do
            identified_by :owner
            reference_to Team, as: :owner
          end
        end

        board = bluebook.aggregate("Board")
        expect(board.identity_paths).to eq(["owner"])
        expect(board.identified_by).to eq(:owner)
      end

      it "no longer takes a block at all — not even alongside a field name" do
        expect do
          Hecksagain::Bluebook::DSL::AggregateBuilder.build("Both") do
            identified_by(:id) { id.value }
          end
        end.to raise_error(Malformed, /identified_by no longer takes a block/)
      end

      it "works the same way on an entity, deriving from the OWNING AGGREGATE's own value object" do
        bluebook = build_bluebook("Games") do
          aggregate "Bracket" do
            identified_by :bracket_id
            attribute :bracket_id, BracketId
            value_object("BracketId") { attribute :value, String }
            value_object("GameId")    { attribute :value, String }

            entity "Game" do
              identified_by :game_id
              attribute :game_id, GameId
            end
          end
        end

        game = bluebook.aggregate("Bracket").entities.first
        expect(game.identity_paths).to eq(["game_id.value"])
        expect(game.identified_by).to eq(:game_id)
      end
    end

    it "refuses as: on the bare-field-name form — there is no field left it could rename" do
      expect do
        build_aggregate("Thing") do
          value_object("Name") { attribute :value, String }
          attribute :name, Name
          identified_by :name, as: :other
        end
      end.to raise_error(Malformed, /Thing\.identified_by takes no as: — name the declared field itself/)
    end

    it "refuses the value-object type form in LIVE source — it used to mint the attribute, and minting is gone" do
      expect do
        build_aggregate("Order") do
          identified_by PizzaName
          value_object("PizzaName") { attribute :value, String }
        end
      end.to raise_error(Malformed, /Thing\.identified_by no longer takes a value object — declare the attribute first/)
    end

    # LEGACY — `identified_by ValueObject, as: field` minted the attribute
    # from the type; ADR 0025 ("Identity") removes it from LIVE source, but
    # frozen era text minted under it must still parse (S0a's own bridge).
    # `MetaValidator.while_shadow_parsing` is what `EraGuard.shadow_parse`
    # wraps its own eval in — these tests exercise the SAME mechanism
    # directly, at the DSL layer, rather than round-tripping through a
    # real file on disk the way `spec/shadow_parse_spec.rb` does end to end.
    describe "identified_by ValueObject — LEGACY, admitted only while shadow-parsing" do
      def legacy(&block)
        Hecksagain::Bluebook::MetaValidator.while_shadow_parsing { yield }
      end

      it "mints the attribute AND derives its path, no separate attribute call needed" do
        found = legacy do
          build_aggregate("Order") do
            identified_by PizzaName
            value_object("PizzaName") { attribute :value, String }
          end
        end

        expect(found.identified_by).to eq(:pizza_name)
        expect(found.identity_paths).to eq(["pizza_name.value"])
        expect(found.attributes.map { |a| [a.name, a.type] }).to eq([[:pizza_name, "PizzaName"]])
      end

      it "as: overrides the minted attribute's own name" do
        found = legacy do
          build_aggregate("Order") do
            identified_by PizzaName, as: :name
            value_object("PizzaName") { attribute :value, String }
          end
        end

        expect(found.identified_by).to eq(:name)
        expect(found.identity_paths).to eq(["name.value"])
        expect(found.attributes.map(&:name)).to eq([:name])
      end

      it "refuses a value object with more than one field, naming every candidate" do
        expect do
          legacy do
            build_aggregate("Thing") do
              identified_by ThingRef
              value_object("ThingRef") do
                attribute :value, String
                attribute :pad, Integer
              end
            end
          end
        end.to raise_error(Malformed, /identified_by names ThingRef, which has 2 fields \(value, pad\)/)
      end

      it "refuses a type naming no declared value object" do
        expect do
          legacy { build_aggregate("Thing") { identified_by Nonexistent } }
        end.to raise_error(Malformed, /identified_by names Nonexistent, which is not a declared value object/)
      end

      it "works the same way on an entity, minting from the OWNING AGGREGATE's own value object" do
        bluebook = legacy do
          build_bluebook("Games") do
            aggregate "Bracket" do
              identified_by :bracket_id
              attribute :bracket_id, BracketId
              value_object("BracketId") { attribute :value, String }
              value_object("WinnerRef") { attribute :value, String }

              entity "Game" do
                identified_by WinnerRef, as: :winner
              end
            end
          end
        end

        game = bluebook.aggregate("Bracket").entities.first
        expect(game.identified_by).to eq(:winner)
        expect(game.identity_paths).to eq(["winner.value"])
        expect(game.attributes.map { |a| [a.name, a.type] }).to eq([[:winner, "WinnerRef"]])
      end
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

    it "invariant declares an aggregate-level rule, checked after every command" do
      built = build_aggregate("Invarianted") do
        value_object("Balance") { attribute :cents, Integer }
        attribute :balance, Balance

        invariant("the balance never goes negative") { balance.cents >= 0 }
      end

      expect(built.invariants.map(&:description)).to eq(["the balance never goes negative"])
      expect(built.invariants.first.canonical).to include("cents")
    end

    it "given at the aggregate level declares a precondition once, and a command names it back" do
      built = build_aggregate("Preconditioned") do
        value_object("Status") { attribute :value, String }
        attribute :status, Status

        given("the record is open") { status.value == "open" }

        command("Close") { given("the record is open") }
      end

      expect(built.preconditions.map(&:description)).to eq(["the record is open"])
      expect(built.commands.first.givens.map(&:description)).to eq(["the record is open"])
      expect(built.commands.first.givens.first.canonical).to eq(built.preconditions.first.canonical)
    end

    it "given refuses a command that names a precondition the aggregate never declared" do
      expect do
        build_aggregate("Unpreconditioned") do
          command("Close") { given("the record is open") }
        end
      end.to raise_error(Malformed, /names no precondition Thing declares/)
    end

    it "projects declares a field read locally through a reference" do
      bluebook = build_bluebook("Projecting") do
        aggregate("Customer") do
          identified_by :id
          lifecycle :status, default: "active" do
            transition "Suspend" => "suspended", from: "active"
          end
        end

        aggregate("Account") do
          identified_by :id
          reference_to Customer

          projects :customer_status, from: :"customer.status"
        end
      end

      field = bluebook.aggregate("Account").projected_fields.first
      expect(field.name).to eq(:customer_status)
      expect(field.reference).to eq(:customer)
      expect(field.remote_field).to eq(:status)
    end

    it "projects refuses a from: that does not name reference.field" do
      expect do
        build_aggregate("MalformedProjection") do
          projects :nope, from: :bare_word
        end
      end.to raise_error(Malformed, /reference\.field/)
    end

    it "projects refuses reading through something that is not a reference_to" do
      expect do
        build_aggregate("NotAReference") do
          value_object("Status") { attribute :value, String }
          attribute :status, Status

          projects :nope, from: :"status.value"
        end
      end.to raise_error(Malformed, /never declares.*as a reference_to/)
    end

    it "projects refuses a remote field the target aggregate never declares" do
      expect do
        build_bluebook("UnknownRemoteField") do
          aggregate("Customer") { identified_by :id }

          aggregate("Account") do
            identified_by :id
            reference_to Customer

            projects :nope, from: :"customer.nonexistent"
          end
        end
      end.to raise_error(Malformed, /never declares/)
    end

    it "projects refuses landing on a reference or value object, not a scalar" do
      expect do
        build_bluebook("NonScalarProjection") do
          aggregate("Region") { identified_by :id }

          aggregate("Customer") do
            identified_by :id
            reference_to Region
          end

          aggregate("Account") do
            identified_by :id
            reference_to Customer

            projects :nope, from: :"customer.region"
          end
        end
      end.to raise_error(Malformed, /not a scalar/)
    end

    it "command's from: guards against the lifecycle field, without transitioning it" do
      bluebook = build_bluebook("Guarding") do
        aggregate("Door") do
          identified_by :id

          lifecycle :status, default: "open" do
            transition "Shut" => "shut", from: "open"
          end

          command("Peek", from: "open")
        end
      end

      command = bluebook.aggregate("Door").command("Peek")
      expect(command.from).to eq("open")
      expect(command.mutations).to be_empty
    end

    it "command's from: refuses when the aggregate declares no lifecycle to check it against" do
      expect do
        build_aggregate("Lifecycleless") { command("Go", from: "open") }
      end.to raise_error(Malformed, /guards from: \["open"\], but Thing declares no lifecycle/)
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

      expect([line.hecks_name, line.identified_by]).to eq(["OrderLine", :sku])
      expect(line.attribute(:quantity).type).to eq("Quantity")
    end

    it "query records filters, ordering and a cap as DATA, never a proc" do
      found = build_aggregate("Readable") do
        # The fields the query below asks about. A query must name a field the
        # aggregate declares (AggregateBuilder#seal_query_targets), so the
        # fixture declares them instead of asking into a void.
        value_object("Name") { attribute :value, String }
        attribute :name, Name
        lifecycle :status, default: "available" do
          transition "Retire" => "retired", from: "available"
        end

        query "Available" do
          where(status: "available")
          order_by :name, :desc
          limit 10
          offset 5
          nulls :last
          authorize :customer_access, tenant: :account_id
          inspect_query :sql
        end
      end.queries.first

      expect(found.name).to eq("Available")
      expect(found.wheres.map(&:to_h)).to eq([{ field: "status", op: "eq", value: %q("available") }])
      expect(found.order_by.to_h).to eq({ field: "name", direction: "desc" })
      expect(found.limit.to_h).to eq({ value: "10" })
      expect(found.offset.to_h).to eq({ value: "5" })
      expect(found.null_semantics.to_h).to eq({ mode: "last" })
      expect(found.authorization.to_h).to eq({ policy: "customer_access", tenant: "account_id" })
      expect(found.inspection.to_h).to eq({ mode: "sql" })
    end

    it "query refuses cursor at build — no interpreter implements cursor pagination" do
      expect {
        build_aggregate("Cursored") do
          value_object("Name") { attribute :value, String }
          attribute :name, Name

          query "Available" do
            where(name: "x")
            cursor :after
          end
        end
      }.to raise_error(Hecksagain::Bluebook::DSL::Malformed, /declares cursor, but no interpreter implements cursor pagination/)
    end

    it "query reads a comparator from the hash form" do
      found = build_aggregate("Compared") do
        value_object("Price") { attribute :cents, Integer }
        attribute :price, Price

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

    describe "a query's own block parameter, derived from the owner's already-declared attribute" do
      it "derives the block parameter's type from the aggregate's own matching attribute, no attribute call needed" do
        found = build_aggregate("Submission") do
          value_object("DecisionRef") { attribute :value, String }
          attribute :decision, DecisionRef

          query "ForDecision" do |decision|
            where decision: :decision
          end
        end.queries.first

        expect(found.attributes.map { |a| [a.name, a.type] }).to eq([[:decision, "DecisionRef"]])
      end

      it "still works when the block also declares the attribute explicitly (no duplicate)" do
        found = build_aggregate("Submission") do
          value_object("DecisionRef") { attribute :value, String }
          attribute :decision, DecisionRef

          query "ForDecision" do |decision|
            attribute :decision, DecisionRef
            where decision: :decision
          end
        end.queries.first

        expect(found.attributes.map(&:name)).to eq([:decision])
      end

      it "carries optional: true through from the owner's own attribute" do
        found = build_aggregate("Submission") do
          value_object("Note") { attribute :value, String }
          attribute :note, Note, optional: true

          query "ByNote" do |note|
            where note: :note
          end
        end.queries.first

        expect(found.attributes.first.optional?).to eq(true)
      end

      it "leaves a block parameter alone when nothing on the owner matches it — no attribute silently invented" do
        found = build_aggregate("Submission") do
          value_object("Name") { attribute :value, String }
          attribute :name, Name

          query "Broken" do |nonexistent|
            where name: "open"
          end
        end.queries.first

        expect(found.attributes).to be_empty
      end

      it "derives from the OWNING ENTITY's own attribute too, not just an aggregate's" do
        bluebook = build_bluebook("Games") do
          aggregate "Bracket" do
            identified_by :bracket_id
            attribute :bracket_id, BracketId
            value_object("BracketId") { attribute :value, String }
            value_object("GameId")    { attribute :value, String }
            value_object("WinnerRef") { attribute :value, String }

            entity "Game" do
              identified_by :game_id
              attribute :game_id, GameId
              attribute :winner, WinnerRef

              query "WinsByOption" do |winner|
                where winner: :winner
              end
            end
          end
        end

        found = bluebook.aggregate("Bracket").entities.first.queries.first
        expect(found.attributes.map { |a| [a.name, a.type] }).to eq([[:winner, "WinnerRef"]])
      end
    end

    # THE QUERY SEAL — the same gate sets gets, closing the same silence.
    # Every case here used to build cleanly and answer wrongly forever: a
    # where over an undeclared field matches nothing on every adapter, an
    # ordered comparator over text is answered differently per adapter (the
    # reference interpreter quietly matches no rows; SQL compares
    # lexicographically), a :symbol naming no argument resolves to nil, and a
    # dotted path is answered by SQL and silently ignored by Memory.
    describe "a query the aggregate cannot answer" do
      it "refuses a where over a field nothing declares" do
        expect do
          build_aggregate("Asking") { query("Lost") { where(price: { lt: 500 }) } }
        end.to raise_error(Malformed, /asks about price, which Thing never declares.*matches nothing and refuses nothing/)
      end

      it "refuses an order_by over a field nothing declares" do
        expect do
          build_aggregate("Sorting") { query("Lost") { order_by :price } }
        end.to raise_error(Malformed, /asks about price, which Thing never declares/)
      end

      it "refuses an ordered comparator over a field that holds no number" do
        expect do
          build_aggregate("Texting") do
            value_object("Label") { attribute :value, String }
            attribute :label, Label
            query("Sorted") { where(label: { gt: "m" }) }
          end
        end.to raise_error(Malformed, /compares label with gt.*holds no number.*adapters answer differently/m)
      end

      it "refuses an ordered comparator over the lifecycle field" do
        expect do
          build_aggregate("Cycling") do
            lifecycle :status, default: "open" do
              transition "Close" => "closed", from: "open"
            end
            query("Sorted") { where(status: { lt: "open" }) }
          end
        end.to raise_error(Malformed, /compares status with lt.*lifecycle field, which holds text/m)
      end

      it "refuses a :symbol value naming no declared query argument" do
        expect do
          build_aggregate("Arguing") do
            value_object("Price") { attribute :cents, Integer }
            attribute :price, Price
            query("Cheap") { where(price: { lt: :ceiling }) }
          end
        end.to raise_error(Malformed, /resolves :ceiling from its arguments, but declares no ceiling attribute/)
      end

      it "admits a dotted path that lands on a scalar member, at any depth" do
        aggregate = build_aggregate("Nesting") do
          value_object("Price") { attribute :cents, Integer }
          value_object("Pizza") { attribute :price, Price }
          attribute :pizza, Pizza
          query("Cheap") do
            where(:"pizza.price.cents" => { lt: 500 })
            order_by :"pizza.price.cents", :desc
          end
        end

        expect(aggregate.queries.first.wheres.first.field.to_s).to eq("pizza.price.cents")
      end

      it "refuses a dotted path that lands on a value object rather than a scalar" do
        expect do
          build_aggregate("Landing") do
            value_object("Price") { attribute :cents, Integer }
            value_object("Pizza") { attribute :price, Price }
            attribute :pizza, Pizza
            query("Cheap") { where(:"pizza.price" => { lt: 500 }) }
          end
        end.to raise_error(Malformed, /asks about pizza\.price, which lands on a value object, not a scalar/)
      end

      it "refuses an ordered comparator on a dotted path to a non-numeric scalar" do
        expect do
          build_aggregate("Lettering") do
            value_object("Label") { attribute :text, String }
            value_object("Pizza") { attribute :label, Label }
            attribute :pizza, Pizza
            query("Sorted") { where(:"pizza.label.text" => { gt: "m" }) }
          end
        end.to raise_error(Malformed, /compares pizza\.label\.text with gt.*holds no number/m)
      end

      describe "a slash path that hops through a reference" do
        def build_hop_bluebook(name = "Hopping", client: nil, &proposal_query)
          build_bluebook(name) do
            aggregate "Client" do
              identified_by :name
              attribute :name, ClientName
              value_object("ClientName") { attribute :value, String }
              lifecycle :status, default: "active" do
                transition "Churn" => "churned", from: "active"
              end
              instance_eval(&client) if client
            end

            aggregate "Proposal" do
              identified_by :number
              reference_to Client
              attribute :number, ProposalNumber
              value_object("ProposalNumber") { attribute :value, String }
              instance_eval(&proposal_query)
            end
          end
        end

        it "admits a hop that lands on a scalar the target declares" do
          bluebook = build_hop_bluebook do
            query("AwaitingReply") { where(:"client/status" => "active") }
          end

          expect(bluebook.aggregate("Proposal").queries.first.wheres.first.field.to_s).to eq("client/status")
        end

        it "admits a WHERE hop with an ordered comparator — the target's own field decides, not the ask" do
          expect do
            build_hop_bluebook(client: proc { value_object("Balance") { attribute :cents, Integer }; attribute :balance, Balance }) do
              query("HighValue") { where(:"client/balance.cents" => { gt: 500 }) }
            end
          end.not_to raise_error
        end

        it "refuses ORDER BY through a hop outright — an ask is ordered by its own rows, not a candidate set" do
          expect do
            build_hop_bluebook do
              query("BadOrder") { order_by :"client/status" }
            end
          end.to raise_error(Malformed, %r{orders by client/status, which hops through a reference})
        end

        it "refuses a hop into an aggregate this chapter never declares" do
          expect do
            build_bluebook("Dangling") do
              aggregate "Proposal" do
                identified_by :number
                reference_to Client
                attribute :number, ProposalNumber
                value_object("ProposalNumber") { attribute :value, String }
                query("Bad") { where(:"client/status" => "active") }
              end
            end
          end.to raise_error(Malformed, %r{asks about client/status, which hops to Client, which this chapter never declares})
        end

        it "refuses a hop whose tail names nothing the target declares" do
          expect do
            build_hop_bluebook do
              query("Bad") { where(:"client/nonexistent" => "x") }
            end
          end.to raise_error(Malformed, /hops to Client and then asks about nonexistent, which Client never declares/)
        end

        # S9, ADR 0025 — an entity's own `reference_to` (EntityBuilder,
        # added after `validate_query_hops!`'s own comment first claimed
        # "an entity has no reference_to at all") went uncheckable at
        # declaration and unresolved at runtime: tier-1 sealing deferred
        # the hop the same way an aggregate's does, but nothing at tier 2
        # ever walked an entity's own queries to check the deferral, and
        # `QueryInterpreter#entity_rows` never follows a reference either
        # — a where over a piece's own hop built cleanly and then matched
        # nothing, forever, on every adapter. Refused outright now.
        it "refuses a hop where-clause on an entity's own query" do
          expect do
            build_bluebook("PieceHop") do
              aggregate "Board" do
                identified_by :tag
                attribute :tag, BoardTag
                value_object("BoardTag") { attribute :value, String }

                entity "Card" do
                  identified_by :sequence
                  attribute :sequence, Integer
                  reference_to Product

                  query("ForProduct") { where(:"product/sku" => "widget") }
                end
              end

              aggregate "Product" do
                identified_by :sku
                attribute :sku, ProductSku
                value_object("ProductSku") { attribute :value, String }
              end
            end
          end.to raise_error(Malformed,
                              %r{Board::Card\.ForProduct asks about product/sku, which hops through Card's own reference})
        end

        it "refuses a hop whose tail lands on a value object rather than a scalar" do
          # A BARE tail landing on a value object ("client.balance") is
          # fine — the same one-level convention a same-aggregate bare
          # field already gets (query_agreement_spec.rb's AtLeast500Desc
          # does exactly this). It takes a SECOND dotted level, landing
          # on a nested value object instead of finally reaching a
          # scalar, to trigger this refusal — Box -> Price, mirroring
          # the existing same-aggregate "lands on a value object" spec's
          # own Pizza -> Price shape above.
          client = proc do
            value_object("Price") { attribute :cents, Integer }
            value_object("Box")   { attribute :price, Price }
            attribute :box, Box
          end

          expect do
            build_hop_bluebook(client: client) do
              query("Bad") { where(:"client/box.price" => { gt: 500 }) }
            end
          end.to raise_error(Malformed, /hops to Client and then asks about box\.price, which lands on a value object, not a scalar/)
        end

        it "refuses an ordered comparator on a hop's tail when it holds no number" do
          expect do
            build_hop_bluebook do
              query("Bad") { where(:"client/status" => { gt: "active" }) }
            end
          end.to raise_error(Malformed, %r{compares client/status with gt after hopping to Client.*is the lifecycle field, which holds text}m)
        end

        it "refuses an ordered comparator on a hop's tail that's a real attribute holding no number" do
          expect do
            build_hop_bluebook(client: proc { attribute :note, String }) do
              query("Bad") { where(:"client/note" => { gt: "z" }) }
            end
          end.to raise_error(Malformed, %r{compares client/note with gt after hopping to Client.*holds no number}m)
        end

        it "a multi-hop chain reads left to right, outward to inward" do
          bluebook = build_bluebook("MultiHop") do
            aggregate "Client" do
              identified_by :name
              attribute :name, ClientName
              value_object("ClientName") { attribute :value, String }
              lifecycle :status, default: "active" do
                transition "Churn" => "churned", from: "active"
              end
            end

            aggregate "Engagement" do
              identified_by :reference
              reference_to Client
              attribute :reference, EngagementRef
              value_object("EngagementRef") { attribute :value, String }
            end

            aggregate "Proposal" do
              identified_by :number
              reference_to Engagement
              attribute :number, ProposalNumber
              value_object("ProposalNumber") { attribute :value, String }
              query("AwaitingReply") { where(:"engagement/client/status" => "active") }
            end
          end

          expect(bluebook.aggregate("Proposal").queries.first.wheres.first.field.to_s)
            .to eq("engagement/client/status")
        end

        it "admits a self-referential hop chain — revisiting the same aggregate TYPE is not a cycle" do
          expect do
            build_bluebook("SelfRef") do
              aggregate "Node" do
                identified_by :label
                reference_to Node, as: :parent
                attribute :label, NodeLabel
                value_object("NodeLabel") { attribute :value, String }
                query("GrandparentLabel") { where(:"parent/parent/label" => "root") }
              end
            end
          end.not_to raise_error
        end

        it "refuses a hop chain deep enough to be a mistake, not because anything could loop forever" do
          expect do
            build_bluebook("TooDeep") do
              aggregate "Node" do
                identified_by :label
                reference_to Node
                attribute :label, NodeLabel
                value_object("NodeLabel") { attribute :value, String }
                nine = (["node"] * 9 + ["label"]).join("/")
                query("TooFar") { where(nine.to_sym => "root") }
              end
            end
          end.to raise_error(Malformed, /whose hop chain reaches 8 references deep/)
        end

        # `/` CROSSES INTO ANOTHER RECORD, `.` WALKS FIELDS INSIDE THIS ONE
        # (ADR 0025, "References") — the operator alone answers which kind
        # of path this is, whatever the reference happens to be named. A
        # reference declared `as: :studio` gets no special-cased spelling
        # either way: `studio.x` never hops, no matter what `studio` names,
        # and `studio/x` always does.
        it "a dot onto a reference attribute never hops — it dead-ends the same way any dotted path onto a non-value-object does" do
          expect do
            build_bluebook("NoDotHop") do
              aggregate "Studio" do
                identified_by :name
                attribute :name, StudioName
                value_object("StudioName") { attribute :value, String }
              end

              aggregate "Piece" do
                identified_by :tag
                reference_to Studio, as: :studio
                attribute :tag, PieceTag
                value_object("PieceTag") { attribute :value, String }
                query("Bad") { where(:"studio.name" => "x") }
              end
            end
          end.to raise_error(Malformed, /asks about studio\.name, which Piece never declares/)
        end

        it "a slash onto the same reference IS the hop" do
          bluebook = build_bluebook("SlashHop") do
            aggregate "Studio" do
              identified_by :name
              attribute :name, StudioName
              value_object("StudioName") { attribute :value, String }
            end

            aggregate "Piece" do
              identified_by :tag
              reference_to Studio, as: :studio
              attribute :tag, PieceTag
              value_object("PieceTag") { attribute :value, String }
              query("Good") { where(:"studio/name.value" => "x") }
            end
          end

          expect(bluebook.aggregate("Piece").queries.first.wheres.first.field.to_s).to eq("studio/name.value")
        end
      end

      it "admits the shapes both adapters answer identically" do
        aggregate = build_aggregate("Sound") do
          value_object("Money")  { attribute :cents, Integer }
          value_object("Name")   { attribute :value, String }
          value_object("Tag")    { attribute :name, String }
          attribute :balance, Money
          attribute :name,    Name
          attribute :tags,    list_of(Tag)
          lifecycle :status, default: "open" do
            transition "Close" => "closed", from: "open"
          end
          query "Everything" do
            attribute :floor, Money
            where(status: { in: "open,closed" }, balance: { lt: :floor },
                  tags: { contains: "hot" }, name: { ne: "x" })
            order_by :name
            limit 10
          end
        end

        expect(aggregate.queries.first.wheres.size).to eq(4)
      end
    end

    it "reference_to another root is an attribute, and leaves the command creating" do
      command = build_bluebook("Open") do
        aggregate("Customer") do
          identified_by :id
          description "A customer"
        end
        aggregate("Thing") do
          identified_by :id
          command("Do") { reference_to "Customer" }
        end
      end.aggregate("Thing").command("Do")

      expect(command.creates?).to be true
      # The GRAPH holds the edge and the EXPORT holds the spelling. Both of these
      # assertions passed unchanged through the reference crossing, because
      # `Reference` carried an `==` that compared equal to the string it
      # replaced — so they went on affirming the pre-crossing truth for a whole
      # commit. The shim is gone ; they say what is actually there.
      #
      # `customer`, not `customer_id` (ADR 0025, "References") — `reference_to`
      # mints the bare name now.
      expect(command.attribute(:customer).type.target_name).to eq("Customer")
      expect(command.attribute(:customer).to_h[:type]).to eq("Reference<Customer>")
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
          trigger Payment::Charge
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

    it "reference_to points at another root by its identity, minting the bare name — no _id" do
      aggregate = build_bluebook("Referring") do
        aggregate("Pizza") do
          identified_by :id
          description "A pizza"
        end
        aggregate("Thing") do
          identified_by :id
          reference_to Pizza
        end
      end.aggregate("Thing")
      expect(aggregate.attribute(:pizza).type.target_name).to eq("Pizza")
      expect(aggregate.attribute(:pizza).to_h[:type]).to eq("Reference<Pizza>")
    end

    # `has_many`, `has_one`, `belongs_to` — GONE (ADR 0025, "References").
    # All three were sugar over `reference_to`, differing from its default
    # only in the attribute name they minted — no `_id` suffix. `reference_to`
    # mints that same bare name now, so the three have no work left to do,
    # and refuse live rather than silently double as `reference_to`'s alias.
    it "has_one is gone — reference_to mints the same bare name, no _id" do
      expect do
        build_bluebook("Owning") do
          aggregate("Profile") do
            identified_by :id
            description "A profile"
          end
          aggregate("Account") do
            identified_by :id
            has_one Profile
          end
        end
      end.to raise_error(Malformed, /Account\.has_one is gone — reference_to Profile mints the same bare name now/)
    end

    it "belongs_to is gone — same refusal, same replacement" do
      expect do
        build_bluebook("Dependent") do
          aggregate("Team") do
            identified_by :id
            description "A team"
          end
          aggregate("Player") do
            identified_by :id
            belongs_to Team
          end
        end
      end.to raise_error(Malformed, /Player\.belongs_to is gone — reference_to Team mints the same bare name now/)
    end

    it "has_many is gone — it also LIED, singularising the target into one scalar rather than a list" do
      expect do
        build_bluebook("Holding") do
          aggregate("Invoice") do
            identified_by :id
            description "An invoice"
          end
          aggregate("Ledger") do
            identified_by :id
            has_many Invoices
          end
        end
      end.to raise_error(Malformed, /Ledger\.has_many is gone — reference_to Invoice mints the same bare name now/)
    end

    it "reference_to still takes as: to override the default name, the way has_* used to" do
      aggregate = build_bluebook("Aliased") do
        aggregate("Warehouse") do
          identified_by :id
          description "A warehouse"
        end
        aggregate("Shipment") do
          identified_by :id
          reference_to Warehouse, as: :origin
          reference_to Warehouse, as: :destination
        end
      end.aggregate("Shipment")

      expect(aggregate.attribute(:origin).type.target_name).to eq("Warehouse")
      expect(aggregate.attribute(:destination).type.target_name).to eq("Warehouse")
    end

    it "value_object declares a VO inside the aggregate that uses it" do
      aggregate = build_aggregate("Valued") { value_object("Part") { attribute :size, Integer } }
      expect(aggregate.value_object("Part").attribute(:size).type).to eq("Integer")
    end

    it "command declares a command" do
      expect(build_aggregate("Commanded") { command("Do") }.commands.map(&:hecks_name)).to eq(["Do"])
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

    it "provenance records where a concept came from, as a literal Hash" do
      origin = { source: "HecksCanonical", source_id: "command:thing.do", source_version: "1.0" }
      command = build_command("CmdProvenance") { provenance from: origin }

      expect(command.provenance).to eq(origin)
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

    it "sets to: a symbol reads a command argument — a genuine remap, a different field" do
      mutation = build_command("CmdSetArg") { sets :status, to: :new_status }.mutations.first

      expect([mutation.target, mutation.op]).to eq([:status, :set])
      expect(mutation.to_h[:source]).to eq(kind: "argument", name: "new_status")
    end

    it "sets to: anything else is a literal" do
      mutation = build_command("CmdSetLit") { sets :status, to: "sold" }.mutations.first
      expect(mutation.to_h[:source]).to eq(kind: "literal", value: "sold")
    end

    # Real coverage for item 12e's plumbing (migration plan task 4/7/8):
    # sets's UNSET-sentinel rewrite -- to: false no longer reads as
    # absent, and a bare positional second argument is boolean shorthand
    # for to:. remove:/multiply:/clamp: are covered by their own items'
    # dispatch-level specs (13/15/16); this file only proves the DSL
    # surface itself parses and records the right op.
    it "sets to: false is a real mutation, not an absent to:" do
      mutation = build_command("CmdSetToFalse") { sets :status, to: false }.mutations.first

      expect(mutation.op).to eq(:set)
      expect(mutation.to_h[:source]).to eq(kind: "literal", value: false)
    end

    it "sets :field, true reads as to: true — a bare positional boolean shorthand" do
      mutation = build_command("CmdSetPositional") { sets :status, true }.mutations.first

      expect(mutation.op).to eq(:set)
      expect(mutation.to_h[:source]).to eq(kind: "literal", value: true)
    end

    it "sets :field, true defers to an explicit to: when both are given" do
      mutation = build_command("CmdSetPositionalLoses") { sets :status, true, to: "explicit" }.mutations.first

      expect(mutation.to_h[:source]).to eq(kind: "literal", value: "explicit")
    end

    it "sets still refuses two operations at once with the new keyword list named" do
      expect { build_command("CmdSetTornNew") { sets :status, to: "a", remove: :b } }
        .to raise_error(Hecksagain::Bluebook::DSL::Malformed, /tries to set and remove/)
    end

    it "sets append: pushes a built value object onto a list" do
      mutation = build_command("CmdAppend") { sets :parts, append: { size: :size } }.mutations.first

      expect([mutation.target, mutation.op]).to eq([:parts, :append])
      expect(mutation.to_h[:fields]).to eq(size: ":size")
    end

    it "sets increment: reads a command argument to add" do
      mutation = build_command("CmdInc") { sets :balance, increment: :amount }.mutations.first

      expect([mutation.target, mutation.op]).to eq([:balance, :increment])
      expect(mutation.to_h[:source]).to eq(kind: "argument", name: "amount")
    end

    it "sets decrement: takes a literal amount away" do
      mutation = build_command("CmdDec") { sets :lives, decrement: 1 }.mutations.first

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

  describe "a domain port" do
    def build_domain_port(&block)
      registry = in_registry do
        Hecks.bluebook("DomPort") do
          aggregate("Thing") do
            identified_by :thing_id
          end
        end
        Hecks.hecksagon("DomPort") { DomPort::Thing.port("Gateway", &block) }
      end
      registry.bluebook("DomPort").aggregate("Thing").port("Gateway")
    end

    it "operation adds a named operation" do
      port = build_domain_port do
        operation("Receive") do
          reference_to Thing, as: :thing_id
          emits "Received"
        end
      end

      expect(port.operation("Receive").hecks_name).to eq("Receive")
    end

    # THE DRIVEN HALF, reached through the same `port` call — registered
    # the same way `Hecks.port`'s own top-level method registers one
    # (`registry.ports`, not the aggregate's own IR — that's where an
    # operations-shaped port lands, checked above).
    it "verb builds a resource-style port, registered the same way Hecks.port is" do
      registry = in_registry do
        Hecks.bluebook("DomPortVerb") do
          aggregate("Thing") do
            identified_by :thing_id
          end
        end
        Hecks.hecksagon("DomPortVerb") { DomPortVerb::Thing.port("Checkout") { verb "opened_by" } }
      end

      port = registry.ports["Checkout"]
      expect(port.verb).to eq("opened_by")
      expect(registry.bluebook("DomPortVerb").aggregate("Thing").port("Checkout")).to be_nil
    end

    it "refuses a port declaring both a verb and operations" do
      expect do
        build_domain_port do
          verb "opened_by"
          operation("Receive") do
            reference_to Thing, as: :thing_id
            emits "Received"
          end
        end
      end.to raise_error(Hecksagain::Bluebook::DSL::Malformed, /declares both a verb and operations/)
    end

    it "refuses a port with no verb and no operations" do
      expect { build_domain_port {} }.to raise_error(Hecksagain::Bluebook::DSL::Malformed, /declares no verb and no operations/)
    end

    it "a bare port at a hecksagon's root belongs to the chapter, not one aggregate" do
      registry = in_registry do
        Hecks.bluebook("RootPort") do
          aggregate("Thing") do
            identified_by :thing_id
          end
        end
        Hecks.hecksagon("RootPort") do
          port("Clock") { operation("Tick") { emits "Ticked" } }
        end
      end

      port = registry.bluebook("RootPort").port("Clock")
      expect(port.operation("Tick").emits).to eq(["Ticked"])
    end

    it "a bare verb port at a hecksagon's root registers the same way a bound one does" do
      registry = in_registry do
        Hecks.bluebook("RootPortVerb") do
          aggregate("Thing") do
            identified_by :thing_id
          end
        end
        Hecks.hecksagon("RootPortVerb") { port("Weather") { verb "provided_by" } }
      end

      port = registry.ports["Weather"]
      expect(port.verb).to eq("provided_by")
      expect(registry.bluebook("RootPortVerb").port("Weather")).to be_nil
    end
  end

  describe "a port operation" do
    def build_operation(&block)
      registry = in_registry do
        Hecks.bluebook("PortOp") do
          aggregate("Thing") do
            identified_by :thing_id
          end
        end
        Hecks.hecksagon("PortOp") { PortOp::Thing.port("Gateway") { operation("Do", &block) } }
      end
      registry.bluebook("PortOp").aggregate("Thing").port("Gateway").operation("Do")
    end

    it "reference_to adds a reference attribute, always — no self-reference form" do
      operation = build_operation do
        reference_to Thing, as: :thing_id
        emits "Done"
      end

      expect(operation.attribute(:thing_id).type.target_name).to eq("Thing")
    end

    it "attribute adds a payload field alongside the reference" do
      operation = build_operation do
        reference_to Thing, as: :thing_id
        attribute :amount, Integer
        emits "Done"
      end

      expect(operation.attribute(:amount).type).to eq("Integer")
    end

    it "emits records the event the operation announces" do
      operation = build_operation do
        reference_to Thing, as: :thing_id
        emits "Done"
      end

      expect(operation.emits).to eq(["Done"])
    end

    it "identity_attribute finds the reference targeting the owning aggregate" do
      operation = build_operation do
        reference_to Thing, as: :thing_id
        emits "Done"
      end

      expect(operation.identity_attribute("Thing").name).to eq(:thing_id)
    end

    it "refuses an operation with no reference to its owning aggregate" do
      expect {
        build_operation { emits "Done" }
      }.to raise_error(Hecksagain::Bluebook::DSL::Malformed, /names no reference_to/)
    end

    it "refuses an operation with no emits" do
      expect {
        build_operation { reference_to Thing, as: :thing_id }
      }.to raise_error(Hecksagain::Bluebook::DSL::Malformed, /declares no emits/)
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
