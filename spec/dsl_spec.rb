require "hecks"
require_relative "support/postgres_probe"

RSpec.describe "the DSL surface" do
  def in_registry
    registry = Hecks::Runtime::Registry.new
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

  # A baseline identity so tests for other behavior don't each need their
  # own (MetaValidator requires one). A block's own `identified_by`
  # overrides this, since the builder keeps only the last call.
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

      # Fields the `sets` cases below mutate; a mutation must name a
      # declared field (AggregateBuilder#seal_mutation_targets) or it
      # fails silently.
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
      expect(Hecks.current_registry).to be_nil
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
      hecksagon = registry.hecksagon("Hexed")

      default_bind = hecksagon.binds.find { |b| b.aggregate.nil? }
      expect([default_bind.aggregate, default_bind.verb, default_bind.adapter])
        .to eq([nil, "posted_by", "Carrier"])

      # An aggregate-specific bind still wins over the domain default.
      expect(hecksagon.bind_for("Thing", "posted_by").adapter).to eq("SpecialCarrier")
      # An aggregate with no bind of its own falls back to the default.
      expect(hecksagon.bind_for("OtherThing", "posted_by").adapter).to eq("Carrier")
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

    it ".hecksagon's attaches loads a framework member into the same registry" do
      registry = in_registry do
        Hecks.hecksagon("Hexed") do
          attaches "Governance"
          Hexed::Thing.posted_by("Carrier")
        end
      end

      expect(registry.bluebook("Governance")).not_to be_nil
      expect(registry.bluebook("Governance").aggregate("RoleAssignment")).not_to be_nil
      expect(registry.hecksagon("Hexed").member_chapters).to eq(["Governance"])
    end

    it ".hecksagon's bounded marks this chapter as a bounded context" do
      registry = in_registry do
        Hecks.hecksagon("Hexed") do
          bounded
          Hexed::Thing.posted_by("Carrier")
        end
      end

      expect(registry.hecksagon("Hexed").bounded?).to be true
    end

    it ".hecksagon's attaches ... from: :vendor records the name and needs a registry root to vendor from" do
      # `in_registry`'s bare `Registry.new` sets no root, so this exercises
      # the real refusal a registry with nowhere to vendor from must
      # raise, not a fixture stand-in for it.
      expect do
        in_registry do
          Hecks.hecksagon("Hexed") do
            attaches "payments", from: :vendor
            Hexed::Thing.posted_by("Carrier")
          end
        end
      end.to raise_error(Hecks::Runtime::WiringError, /needs a registry with a root to vendor from/)
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
      end.to raise_error(Hecks::Bluebook::DSL::Malformed, /needs its sql: expression/)
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
      end.to raise_error(Hecks::Bluebook::DSL::Malformed, /needs a default: value/)
    end

    it ".data_translation refuses an unresolved placeholder" do
      expect do
        in_registry do
          Hecks.data_translation("Translated", from: "1", to: "2") do
            aggregate("Thing") { unresolved :cost, candidates: [:amount] }
          end
        end
      end.to raise_error(Hecks::Bluebook::DSL::Malformed, /leaves :cost unresolved/)
    end

    # A typo admitted nowhere in the grammar falls through to Ruby's own
    # NoMethodError, not a DSL-level Malformed.
    it ".data_translation falls through to NoMethodError for a typo admitted nowhere in the grammar" do
      expect do
        in_registry do
          Hecks.data_translation("Translated", from: "1", to: "2") do
            aggregate("Thing") { renmae :cost, to: :amount }
          end
        end
      end.to raise_error(NoMethodError, /renmae/)
    end

    # A word legal elsewhere (Aggregate context) but not inside a
    # TranslationAggregate body still gets WordGate's table-driven
    # refusal, naming this context's legal words.
    it ".data_translation refuses a word admitted elsewhere in the grammar but not here" do
      expect do
        in_registry do
          Hecks.data_translation("Translated", from: "1", to: "2") do
            aggregate("Thing") { identified_by :cost }
          end
        end
      end.to raise_error(Hecks::Bluebook::DSL::Malformed, /not a word TranslationAggregate admits/)
    end

    it ".data_translation falls through to NoMethodError for an unknown top-level word" do
      expect do
        in_registry do
          Hecks.data_translation("Translated", from: "1", to: "2") { banana "Thing" }
        end
      end.to raise_error(NoMethodError, /banana/)
    end

    # Needs a real `Hecks.boot`, not `boot_in_memory`: examples/pizzas
    # declares `persisted_by("PostgresEra")` unconditionally, so this
    # needs a reachable Postgres (`io: true`, self-skipping otherwise).
    it ".boot loads a domain directory and returns the door", :io do
      skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

      runtime = Hecks.boot(File.expand_path("../examples/pizzas", __dir__))
      expect(runtime).to be_a(Hecks::Runtime::Dispatcher)
      expect(runtime.verbs).to include("Pizzas::Order.Purchase")
    end

    # Reads declarations only: no adapter is resolved, so a domain that declares
    # `persisted_by("PostgresEra")` answers without a database.
    it ".describe reads a domain directory, binding no adapter and opening no database" do
      described = Hecks.describe(File.expand_path("../examples/pizzas", __dir__))

      expect(described).to be_a(Hecks::Runtime::Loader::Described)
      expect(described.registry.bluebooks.values.map(&:name)).to include("Pizzas")
    end

    it ".boot_described finishes a boot from what describe loaded, reading nothing again" do
      described = Hecks.describe(File.expand_path("../examples/banking", __dir__))

      runtime = Hecks.boot_described(described, install_doors: false)

      expect(runtime.registry).to be(described.registry)
    end

    it ".boot refuses a declaration loaded outside a boot" do
      expect { Hecks.bluebook("Orphan") { vision "x" } }
        .to raise_error(Hecks::LoadOutsideBoot, /outside a boot/)
    end

    # `.boot_files` is the explicit-file sibling of `.boot`, Memory-
    # persisted so it needs no Postgres. Files are named exactly, not
    # discovered by globbing a directory.
    it ".boot_files loads exactly the files named, in place" do
      root = File.expand_path("../examples/pizzas", __dir__)
      runtime = Hecks.boot_files(
        [File.join(root, "bluebook/pizzas.bluebook"), File.join(root, "pizzas_behaviors.hecksagon")],
        install_doors: false
      )

      expect(runtime).to be_a(Hecks::Runtime::Dispatcher)
      expect(runtime.registry.bluebooks.keys).to eq(%w[Pizzas Governance])
    end
  end

  describe "Hecks.behaviors" do
    it "refuses a call outside the behaviors runner" do
      require "hecks/behaviors"

      expect { Hecks.behaviors("Orphan") { vision "x" } }
        .to raise_error(Hecks::Behaviors::LoadOutsideRunner, /outside/)
    end
  end

  describe "declarations that cannot mean what they say" do
    Malformed = Hecks::Bluebook::DSL::Malformed

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
        .to raise_error(Malformed, /names no identity/)
    end

    it "refuses an unnamed attribute" do
      # a declared value-object type, so the value-object-types rule does not
      # fire first and mask the naming rule this example is about
      expect do
        build_aggregate("Nameless") do
          value_object("Label") { attribute :value, String }
          begin
            attribute "", Object.const_get("Label")
          rescue StandardError
            attribute "", :Label
          end
        end
      end.to raise_error(Malformed, /an attribute is named/)
    end

    # A ValueObject is known by aggregate + name, not `id`; the refusal
    # must quote the actual two-part identity, not an `id` field the
    # category doesn't have.
    it "refuses an aggregate attribute that is not a value object" do
      expect { build_aggregate("Primitive") { attribute :code, String } }
        .to raise_error(Malformed, /no ValueObject with aggregate, name "Primitive:Thing:String"/)
    end

    # A piece is reached through its aggregate, so a command on one
    # addresses the aggregate, never the piece; `CommandBuilder#reference_to`
    # only sets `references` when the target names the owner.
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

    # A command's reference argument is offered to the meta-domain as the
    # head's own id, so resolution failure names which id it looked for.
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

    # A default must fill the shape it's declared on: `default: "open"` on
    # a value-object attribute built cleanly but refused every create at
    # dispatch — refusing consistently is agreement about nothing.
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

    # A name declared twice would survive into the IR as two attributes
    # sharing one name; every downstream reader (mutation target, query
    # field, `Instance#[]`) would silently see only the first.
    it "refuses an attribute name declared twice" do
      expect do
        build_aggregate("DupAttr") do
          value_object("Tag") { attribute :value, String }
          value_object("Size") { attribute :value, Integer }
          attribute :label, Tag
          attribute :label, Size
        end
      end.to raise_error(Malformed, /label is declared twice/)
    end

    it "refuses a relationship whose name collides with an existing attribute" do
      expect do
        build_bluebook("DupRelationship") do
          aggregate("Account") { identified_by { attribute :number, String } }

          aggregate "Portfolio" do
            identified_by { attribute :number, String }
            attribute :account, String
            belongs_to Account
          end
        end
      end.to raise_error(Malformed, /account is declared twice/)
    end

    it "refuses a bare default on an inline one_of closed set the same way" do
      expect do
        build_aggregate("DefaultedInline") do
          attribute :cover, one_of("covered", "open"), default: "open"
        end
      end.to raise_error(Malformed, /Cover is a value object — a default fills its FIELDS/)
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
      expect(spelled.to_h[:ensures].size).to eq(1)
      row = spelled.to_h[:ensures].first
      expect(row).to include(description: "it landed", canonical: "old.balance.cents <= balance.cents")
      # The structured form rides beside the text, derived from it.
      expect(row[:ast]).to eq(Hecks::Bluebook::Expression::AstJson.emit_predicate(row[:canonical]))
    end

    it "records a needed outside fact on the command and in its IR" do
      needing = build_command("Stamped") do
        attribute :now, Instant
        needs :now
      end

      expect(needing.needs).to eq([:now])
      expect(needing.to_h[:needs]).to eq([{ fact: "now" }])
    end

    it "carries no needs on a command that names none" do
      expect(build_command("Plain") { emits "Done" }.to_h[:needs]).to eq([])
    end

    it "refuses a fact the runtime cannot supply" do
      expect do
        build_command("Weathered") do
          attribute :weather, Instant
          needs :weather
        end
      end.to raise_error(Malformed, /cannot supply/)
    end

    it "refuses a need declared twice" do
      expect do
        build_command("Twice") do
          attribute :now, Instant
          needs :now
          needs :now
        end
      end.to raise_error(Malformed, /twice/)
    end

    it "refuses a need with no attribute of that name to fill" do
      expect { build_command("Unfilled") { needs :now } }
        .to raise_error(Malformed, /declares no attribute :now/)
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

    # C4.2 / C3.6 (docs/semantics/bluebook-semantics.md) — effects are one
    # update set (order can't matter), and a rule's `.match?` pattern is
    # held to PatternSubset exactly as an attribute's own `pattern:` is.
    it "refuses a .match? pattern outside PatternSubset in a given — a backreference means different things " \
       "to different engines" do
      expect do
        build_command("Echoed") do
          given("the tag doubles") { tag.value.match?(/(a)\1/) }
        end
      end.to raise_error(Malformed, /given "the tag doubles" matches against "\(a\)\\\\1", which uses a backreference/)
    end

    it "refuses a .match? pattern outside PatternSubset in a policy where too" do
      expect do
        build_bluebook("Watched") do
          policy "Echo" do
            on      "Started"
            where { name.match?(/(?=x)/) }
            trigger "Thing.Next"
          end
        end
      end.to raise_error(Malformed, /Echo's where matches against "\(\?=x\)", which uses a lookahead/)
    end

    # A method call the expression language has no node for parses as a lookup of an attribute that
    # can never exist. It is refused where the rule is built, not on the first dispatch.
    describe "a call the expression language does not support" do
      it "is refused in a value object invariant, naming the expression and the alternative" do
        expect do
          build_aggregate("Statuses") do
            value_object("StatusCode") do
              attribute :value, Integer
              invariant("an http status code is a real one") { value.between?(100, 599) }
            end
          end
        end.to raise_error(Malformed) { |error|
          expect(error.message).to include(
            %(StatusCode's invariant "an http status code is a real one" uses "value.between?(100, 599)"),
            "value >= 100 && value <= 599"
          )
        }
      end

      it "is refused in a given" do
        expect do
          build_command("Ranged") do
            given("the size is small") { balance.between?(1, 9) }
          end
        end.to raise_error(Malformed, /Do's given "the size is small" uses "balance\.between\?\(1, 9\)"/)
      end

      it "is refused in a policy where" do
        expect do
          build_bluebook("Watched") do
            policy "Echo" do
              on      "Started"
              where { count.between?(1, 9) }
              trigger "Thing.Next"
            end
          end
        end.to raise_error(Malformed, /Echo's where uses "count\.between\?\(1, 9\)"/)
      end

      it "does not refuse a bare .nil?, which real bluebooks already declare and which loads" do
        expect do
          build_command("Nilable") do
            given("the tag is assigned") { !status.nil? }
          end
        end.not_to raise_error
      end

      it "leaves the supported spellings alone" do
        expect do
          build_command("Supported") do
            given("the balance is positive") { balance.positive? }
            # rubocop:disable-next Style/ComparableBetween
            given("the balance is a real one") { balance >= 100 && balance <= 599 }
            given("the tag is named") { !status.to_s.empty? }
            given("the tag is one of these") { ["a", "b"].include?(status) }
          end
        end.not_to raise_error
      end
    end

    it "refuses writing one field twice in a command — effects are one update set, not a sequence" do
      expect do
        build_command("Twice") do
          sets :status, to: "open"
          sets :status, to: "closed"
        end
      end.to raise_error(Malformed, /Do writes status twice \(set and set\)/)
    end

    it "then_set is gone — sets is the word now (ADR 0025 reverts the rename)" do
      # `then_set` is reachable only as frozen era text through
      # EraGuard.shadow_parse (Syntax::Keyword carries it as `was:`), never
      # as live syntax.
      expect { build_command("Spelled2") { then_set :balance, increment: :amount } }
        .to raise_error(Malformed, "Do's then_set is gone — sets is the word now")
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
              command("Do") { given("unreadable", &eval("proc { 1 < 2 }")) } # rubocop:disable Style/EvalWithLocation -- deliberately WITHOUT file/line: this fixture exercises the "source could not be read" refusal, which needs an untraceable source_location
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

    # `to_h` must preserve a member field's declared type (e.g. an Integer
    # stays an Integer), not stringify it — indistinguishable otherwise
    # from a value some row spelled as text.
    it "to_h preserves a member field's own declared type, not just its String spelling" do
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

      expect(currency.to_h[:members]).to eq(
        [[["code", "USD"], ["minor_units", 2]], [["code", "JPY"], ["minor_units", 0]]]
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
      # Desugaring keeps the closed set closed; a plain String attribute
      # would let the set mean nothing.
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
            # A bare scalar id short-circuits the `.value` dig
            # (`identity_from`), so this derives from exactly what dispatch
            # supplies — nothing minted.
            identified_by :id

            attribute :kind,   Kind
            attribute :amount, Amount

            value_object("Kind") do
              attribute :name, String
              invariant("current or savings") { ["current", "savings"].include?(name) }
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
      runtime  = Hecks::Runtime::Loader.bind_runtime(
        Hecks::Runtime::Dispatcher.new(registry.tap(&:verify!))
      )

      state = runtime.dispatch_flat("Coerced::Holding.Open", id: "h1",
                               kind: { name: "current" }, amount: { cents: 100, currency: "GBP" }).state

      expect(state[:kind]).to be_a(Hecks::Runtime::Value)
      expect(state[:kind].type_name).to eq("Kind")
      expect(state[:kind][:name]).to eq("current")
    end

    it "identifies a value object by its declared state" do
      registry = account_domain
      runtime  = Hecks::Runtime::Loader.bind_runtime(
        Hecks::Runtime::Dispatcher.new(registry.tap(&:verify!))
      )

      first  = runtime.dispatch_flat("Coerced::Holding.Open", id: "h1",
                                kind: { name: "current" }, amount: { cents: 100, currency: "GBP" }).state[:kind]
      second = runtime.dispatch_flat("Coerced::Holding.Open", id: "h2",
                                kind: { name: "current" }, amount: { cents: 250, currency: "GBP" }).state[:kind]

      expect(first).to eq(second)
      expect(first.to_h).to eq(name: "current")
    end

    it "enforces the invariant on a value object" do
      registry = account_domain
      runtime  = Hecks::Runtime::Loader.bind_runtime(
        Hecks::Runtime::Dispatcher.new(registry.tap(&:verify!))
      )

      expect do
        runtime.dispatch_flat("Coerced::Holding.Open", id: "h2",
                         kind: { name: "offshore" }, amount: { cents: 100, currency: "GBP" })
      end
        .to raise_error(Hecks::Runtime::InvariantViolation, /current or savings/)
    end

    # A bare scalar auto-wraps into a single-field value object's sole
    # attribute (`Value::Coercion#fields_for`); the refusal survives only
    # for a multi-field one like `Amount`, where the scalar can't say
    # which field it means.
    it "refuses a scalar for every multi-field value object" do
      registry = account_domain
      runtime  = Hecks::Runtime::Loader.bind_runtime(
        Hecks::Runtime::Dispatcher.new(registry.tap(&:verify!))
      )

      expect do
        runtime.dispatch_flat("Coerced::Holding.Open", id: "h3",
                         kind: { name: "current" }, amount: "a lot")
      end
        .to raise_error(Hecks::Runtime::TypeMismatch, /pass its fields as an object/)
    end
  end

  describe "a bluebook" do
    # Shared fixture for the two correlates_by dot-resolution refusal specs
    # below: `Ref` nests `Amount`, giving `correlates_by` somewhere to run
    # out of scalar.
    def build_ref_amount_bluebook(domain_name, &process_manager_block)
      build_bluebook(domain_name) do
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

        process_manager("Broken", &process_manager_block)
      end
    end

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
      # `many:` compares each include against the reference; includes
      # resolve at build, so declaration order between include and
      # reference doesn't matter.
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

    # An include with no reference is a rootless read model — a bulk view
    # of its own included head(s), no root record required.
    it "lets a read model include with no reference at all, as a rootless read model" do
      expect do
        build_bluebook("BadModel") do
          read_model("Portfolio") { include Customer }
        end
      end.not_to raise_error
    end

    # A read model naming neither a reference nor any include has nothing
    # to describe at all — the one case that still refuses.
    it "refuses a read model naming neither a reference nor any include" do
      expect do
        build_bluebook("BadModel") do
          read_model("Portfolio") { description "nothing to gather" }
        end
      end.to raise_error(Hecks::Bluebook::DSL::Malformed, /needs an aggregate-head reference or at least one include/)
    end

    it "refuses an empty read-model description" do
      # a reference, so `needs an aggregate-head reference` does not fire first
      # and mask the description rule this case is about
      expect do
        build_bluebook("BadModel") do
          read_model("Portfolio") do
            reference_to Customer
            description ""
          end
        end
      end.to raise_error(Hecks::Bluebook::DSL::Malformed, /a description says something/)
    end

    it "refuses a second reference_to on the same read model" do
      expect do
        build_bluebook("BadModel") do
          read_model("Portfolio") do
            reference_to Customer
            reference_to Account
          end
        end
      end.to raise_error(Hecks::Bluebook::DSL::Malformed, /already has a projection reference/)
    end

    it "refuses a duplicate include alias on the same read model" do
      expect do
        build_bluebook("BadModel") do
          read_model("Portfolio") do
            reference_to Customer
            include Customer, as: :customer
            include Customer, as: :customer
          end
        end
      end.to raise_error(Hecks::Bluebook::DSL::Malformed, /already projects customer/)
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

      expect(model.wheres.first.to_h).to eq(field: "status", op: "eq", value: '"active"')
      expect(model.aggregate_heads).to eq([{ aggregate: "Account", as: :accounts, many: true }])
      expect(model.offset.to_h).to eq(value: "5")
      expect(model.authorization.to_h).to eq(policy: "portfolio_access", tenant: "customer_id")
    end

    it "read_model refuses cursor at build — no interpreter implements cursor pagination" do
      expect do
        build_bluebook("CursoredPortfolio") do
          read_model "Portfolio" do
            reference_to Customer
            include Account

            cursor :after
          end
        end
      end.to raise_error(Hecks::Bluebook::DSL::Malformed, /declares cursor, but no interpreter implements cursor pagination/)
    end

    it "refuses two aggregates that reference each other" do
      expect do
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
      end.to raise_error(Hecks::Bluebook::DSL::Malformed,
                         /reference cycle: (Rider -> Bicycle -> Rider|Bicycle -> Rider -> Bicycle)/)
    end

    # A ring can close through an owned entity's own `reference_to`, not
    # only a direct aggregate-to-aggregate edge; both must feed the same
    # cycle check.
    it "refuses a reference cycle that closes through an owned entity" do
      expect do
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
      end.to raise_error(Hecks::Bluebook::DSL::Malformed,
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

    # `formerly_known_as` drives a real Postgres schema rename at boot and
    # is hashed into the meta-validator's cache key; a chapter reassembled
    # from exported IR must not lose it silently.
    it "formerly_known_as survives onto the wire, not just the live object" do
      expect(build_bluebook("RenamedOnWire") { formerly_known_as "OldName" }.to_h[:formerly_known_as])
        .to eq("OldName")
    end

    it "formerly_known_as is present (nil) on the wire even when a chapter declares none" do
      expect(build_bluebook("NeverRenamed") {}.to_h).to include(formerly_known_as: nil)
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
      # States are derived from the transitions that name them, first-seen
      # order — the same reading `Behaviour::Lifecycle#states` gives an
      # aggregate's own field.
      expect(checkout.states).to eq(["awaiting_payment", "paid"])

      handler = checkout.handler_for("PaymentAuthorized")
      expect([handler.from_state, handler.to_state]).to eq(["awaiting_payment", "paid"])
      expect(handler.dispatches.first.to_h)
        .to eq({ command_name: "Order.Confirm", with_spec: [["order", ":order_id"]], compensates: nil })
      # `correlates_by` must cross the wire as the same bare word Symbol
      # readers expect (`value&.to_sym`); a colon-wrapped or stringified
      # spelling would break that round trip.
      expect(checkout.to_h[:correlates_by]).to eq("order.id")
    end

    # A process manager built straight from the IR class can carry a nil
    # `correlates_by`, even though the DSL itself always refuses to mint
    # one without it; `to_h` must read back `nil`, not the ambiguous `""`.
    it "a process manager's absent correlates_by survives to_h as nil, not an empty string" do
      expect(Hecks::Bluebook::ProcessManager.new(name: "Untethered").to_h[:correlates_by]).to be_nil
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

    # States are derived from the transitions that name them, so this
    # isn't a transition through an undeclared state — it's a transition
    # naming no from: at all, which no admission check would ever match.
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

    # A leg is selected by (event, current state); two from different
    # states are fine, but two from the same state would leave the
    # runtime picking by declaration order, silently.
    it "process_manager refuses two transitions on one event from the same state — the leg would be ambiguous" do
      expect do
        build_bluebook("Ambiguous") do
          process_manager "Broken" do
            correlates_by :"id.value"
            starts_on "Started"
            transition "Next" => "b", from: "a"
            transition "Next" => "c", from: ["z", "a"]
          end
        end
      end.to raise_error(/declares two transitions on "Next" from "a"/)
    end

    it "process_manager accepts two transitions on one event from different states" do
      pm = build_bluebook("TwoLegs") do
        process_manager "Relay" do
          correlates_by :"id.value"
          starts_on "Started"
          transition "Next" => "b", from: "a"
          transition "Next" => "c", from: "b"
        end
      end.process_managers.first

      expect([pm.handler_for("Next", "a").to_state, pm.handler_for("Next", "b").to_state]).to eq(%w[b c])
      expect(pm.handler_for("Next", "c")).to be_nil
    end

    it "process_manager refuses correlates_by that resolves to a value object, not a scalar" do
      # `ref.amount` reaches a real field, but that field's type (`Amount`)
      # is itself a value object, not a scalar — the same one-VO-short
      # mistake `identified_by` already refuses on the aggregate side.
      expect do
        build_ref_amount_bluebook("NonScalarKey") do
          correlates_by :"ref.amount"
          starts_on "Started"
          transition "Started" => "b", from: "a" do
            dispatch Thing::Start
          end
        end
      end.to raise_error(/Amount is a value object, not a scalar/)
    end

    it "process_manager refuses correlates_by naming a field no emitting command declares that shape for" do
      expect do
        build_ref_amount_bluebook("StrandedKey") do
          correlates_by :"ref.currency"
          starts_on "Started"
          transition "Started" => "b", from: "a" do
            dispatch Thing::Start
          end
        end
      end.to raise_error(/Ref has no field "currency"/)
    end

    it "aggregate adds an aggregate" do
      # `identified_by` reads its own source line via Prism, so it needs a
      # line to itself; sharing a line with the outer block would make
      # `block_node_at` read the wrong source (pre-order walk).
      built = build_bluebook("Agged") do
        aggregate("Thing") do
          identified_by :id
        end
      end
      expect(built.aggregates.map(&:name)).to eq(["Thing"])
    end

    it "core, supporting and generic each record a classification" do
      %i[core supporting generic].each_with_index do |keyword, index|
        builder = Hecks::Bluebook::DSL::BluebookBuilder.new("Classified#{index}")
        builder.public_send(keyword)
        expect(builder.classification).to eq(keyword)
      end
    end

    it "resolve_pending_chapter_givens! resolves a bare chapter-given left pending by an earlier file" do
      # Two separate `Hecks.bluebook` calls, same chapter name — the shape
      # a chapter split across real files takes. The reference is
      # deferred, not refused, until `MetaValidator.judge_deferred!` runs
      # after both have loaded.
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Hecks::Bluebook::MetaValidator.defer do
          Hecks.bluebook("SplitGiven") do
            aggregate("Referencer") do
              identified_by :id
              given("shared fact")
            end
          end
          Hecks.bluebook("SplitGiven") do
            aggregate("Declarer") do
              identified_by :id
              given("shared fact") { true }
            end
          end
        end
        Hecks::Bluebook::MetaValidator.judge_deferred!(registry)
      end

      referencer = registry.bluebook("SplitGiven").aggregates.find { |a| a.hecks_name == "Referencer" }
      expect(referencer.preconditions.map(&:canonical)).to eq(["true"])
    end

    # One coherent two-file-load scenario proving a single end-to-end
    # resolution claim; splitting it would separate the deferred
    # declarations from the assertion only the deferred pass produces.
    # rubocop:disable-next RSpec/ExampleLength
    it "resolve_pending_chapter_entity_givens! resolves a bare entity-level given left pending by an " \
       "earlier file, DECLARED ON A DIFFERENT AGGREGATE'S OWN PIECE" do
      # The entity-scoped analogue, one level down: reference and
      # declaration live on a piece under two different aggregates
      # (Account::LedgerEntry / SafeDepositBox::Visit).
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Hecks::Bluebook::MetaValidator.defer do
          Hecks.bluebook("SplitEntityGiven") do
            aggregate("Referencer") do
              identified_by :id
              entity("Piece") do
                identified_by :id
                given("shared fact")
              end
            end
          end
          Hecks.bluebook("SplitEntityGiven") do
            aggregate("Declarer") do
              identified_by :id
              entity("Piece") do
                identified_by :id
                given("shared fact") { true }
              end
            end
          end
        end
        Hecks::Bluebook::MetaValidator.judge_deferred!(registry)
      end

      referencer_piece = registry.bluebook("SplitEntityGiven").aggregates
                                 .find { |a| a.hecks_name == "Referencer" }.entities.first
      expect(referencer_piece.preconditions.map(&:canonical)).to eq(["true"])
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

    # An entity-owned command reaches Dispatcher#dispatch through the same
    # dotted-verb routing as an ordinary command, recursing two levels
    # deep because entities can nest inside entities (ADR 0026).
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

        # `:batch_id` has no matching attribute, resolved bare by the
        # `_id` convention (`resolve_identity_field!`); `:name` unwraps
        # its single-field value object the ordinary way.
        identified_by :batch_id, :name
      end

      expect(identified.identity_paths).to eq(["batch_id", "name.value"])
      expect(identified.identity_heads).to eq([:batch_id, :name])
      expect(identified.identified_by).to be_nil
    end

    # Nothing is minted, so nothing defaults either — an aggregate with no
    # identity can't be created. Uses the raw builder, not
    # `build_aggregate`, which hands fixtures a baseline identity.
    it "identified_by has no default : an aggregate that declares none has none" do
      undeclared = Hecks::Bluebook::DSL::AggregateBuilder.build("Undeclared") {}

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

      # ADR 0025 — an identity head may be a single-field value object, a
      # bare scalar, or a reference; a reference is already a scalar id
      # (`reference_to` mints a bare attribute), so it resolves unchanged.
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
          Hecks::Bluebook::DSL::AggregateBuilder.build("Both") do
            identified_by(:id) { id.value }
          end
        end.to raise_error(Malformed, /identified_by cannot combine a value-object type with a block/)
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

    it "uses a value-object type as the live identity concept and mints its field" do
      identified = build_aggregate("Order") do
        identified_by PizzaName
        value_object("PizzaName") { attribute :value, String }
      end

      expect(identified.identity_paths).to eq(["pizza_name.value"])
      expect(identified.attributes.map { |field| [field.name, field.type] })
        .to include([:pizza_name, "PizzaName"])
    end

    # Frozen era text using the value-object form passes through the
    # explicit shadow boundary directly at the DSL layer — the same
    # mechanism `EraGuard.shadow_parse` wraps its eval in.
    describe "identified_by ValueObject while shadow-parsing" do
      def legacy(&)
        Hecks::Bluebook::MetaValidator.while_shadow_parsing(&)
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

      it "expands a multi-field value object in declaration order" do
        found = legacy do
          build_aggregate("Thing") do
            identified_by ThingRef
            value_object("ThingRef") do
              attribute :value, String
              attribute :pad, Integer
            end
          end
        end

        expect(found.identity_paths).to eq(["thing_ref.value", "thing_ref.pad"])
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

    # The lifecycle field moves only by transition; the state machine is
    # checked whole at build — no `sets` on the field, no `from:` naming
    # an undeclared state, no two transitions for one command.
    it "refuses sets on the lifecycle field — it moves only by transition" do
      expect do
        build_aggregate("Bypassed") do
          lifecycle :status, default: "open" do
            transition "Close" => "closed", from: "open"
          end
          command("Force") { sets :status, to: "closed" }
        end
      end.to raise_error(Malformed, /Force sets status, Thing's lifecycle field/)
    end

    it "refuses two transitions for one command from the same state — which fires would be declaration order" do
      expect do
        build_aggregate("Twice") do
          lifecycle :status, default: "open" do
            transition "Close" => "closed", from: "open"
            transition "Close" => "shut",   from: "open"
          end
        end
      end.to raise_error(Malformed, /declares two transitions for "Close" from the same state/)
    end

    it "keeps two transitions for one command from disjoint states — the current state picks" do
      machine = build_aggregate("Forked") do
        lifecycle :status, default: "open" do
          transition "Close" => "closed",   from: "open"
          transition "Close" => "archived", from: "closed"
        end
      end.lifecycle

      expect(machine.target_for("Close", "closed")).to eq("archived")
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

    it "lifecycle refuses to guess a target when no declared from: admits the current state" do
      machine = build_aggregate("Stalled") do
        lifecycle :status, default: "a" do
          transition "Advance" => "b", from: "a"
          transition "Advance" => "c", from: "b"
        end
      end.lifecycle

      # "z" admits neither declared transition — silently falling back to
      # the first one would be a wrong answer, rather than the loud
      # refusal every real dispatch path gets from `admissible_transition`.
      expect { machine.target_for("Advance", "z") }
        .to raise_error(Hecks::Runtime::WiringError, /no transition for "Advance" admits state "z"/)
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
      expect(found.wheres.map(&:to_h)).to eq([{ field: "status", op: "eq", value: '"available"' }])
      expect(found.order_by.to_h).to eq({ field: "name", direction: "desc" })
      expect(found.limit.to_h).to eq({ value: "10" })
      expect(found.offset.to_h).to eq({ value: "5" })
      expect(found.null_semantics.to_h).to eq({ mode: "last" })
      expect(found.authorization.to_h).to eq({ policy: "customer_access", tenant: "account_id" })
      expect(found.inspection.to_h).to eq({ mode: "sql" })
    end

    it "query refuses cursor at build — no interpreter implements cursor pagination" do
      expect do
        build_aggregate("Cursored") do
          value_object("Name") { attribute :value, String }
          attribute :name, Name

          query "Available" do
            where(name: "x")
            cursor :after
          end
        end
      end.to raise_error(Hecks::Bluebook::DSL::Malformed, /declares cursor, but no interpreter implements cursor pagination/)
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

        expect(found.attributes.first.optional?).to be(true)
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

    # Without this seal, every case here would build cleanly and answer
    # wrongly: an undeclared-field where matches nothing, an ordered
    # comparator differs per adapter, a bad :symbol resolves to nil.
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

      it "infers a symbolic query argument from the compared field" do
        aggregate = build_aggregate("Arguing") do
          value_object("Price") { attribute :cents, Integer }
          attribute :price, Price
          query("Cheap") { where(price: { lt: :ceiling }) }
        end

        ceiling = aggregate.query("Cheap").attribute(:ceiling)
        expect([ceiling.name, ceiling.type.to_s]).to eq([:ceiling, "Price"])
      end

      it "still requires an explicit argument when no compared field supplies its type" do
        expect do
          build_aggregate("Paging") do
            attribute :name, String
            query("Page") { limit :page_size }
          end
        end.to raise_error(Malformed, /resolves :page_size from its arguments, but declares no page_size attribute/)
      end

      it "admits a dotted path that lands on a scalar member, at any depth" do
        aggregate = build_aggregate("Nesting") do
          value_object("Price") { attribute :cents, Integer }
          value_object("Pizza") { attribute :price, Price }
          attribute :pizza, Pizza
          query("Cheap") do
            where("pizza.price.cents": { lt: 500 })
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
            query("Cheap") { where("pizza.price": { lt: 500 }) }
          end
        end.to raise_error(Malformed, /asks about pizza\.price, which lands on a value object, not a scalar/)
      end

      it "refuses an ordered comparator on a dotted path to a non-numeric scalar" do
        expect do
          build_aggregate("Lettering") do
            value_object("Label") { attribute :text, String }
            value_object("Pizza") { attribute :label, Label }
            attribute :pizza, Pizza
            query("Sorted") { where("pizza.label.text": { gt: "m" }) }
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
            query("AwaitingReply") { where("client/status": "active") }
          end

          expect(bluebook.aggregate("Proposal").queries.first.wheres.first.field.to_s).to eq("client/status")
        end

        it "admits a WHERE hop with an ordered comparator — the target's own field decides, not the ask" do
          expect do
            build_hop_bluebook(client: proc {
              value_object("Balance") do
                attribute :cents, Integer
              end
              attribute :balance, Balance
            }) do
              query("HighValue") { where("client/balance.cents": { gt: 500 }) }
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
                query("Bad") { where("client/status": "active") }
              end
            end
          end.to raise_error(Malformed, %r{asks about client/status, which hops to Client, which this chapter never declares})
        end

        it "refuses a hop whose tail names nothing the target declares" do
          expect do
            build_hop_bluebook do
              query("Bad") { where("client/nonexistent": "x") }
            end
          end.to raise_error(Malformed, /hops to Client and then asks about nonexistent, which Client never declares/)
        end

        # An entity's own `reference_to` was uncheckable at declaration
        # and unresolved at runtime; a where over a piece's own hop built
        # cleanly and matched nothing, forever, on every adapter.
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

                  query("ForProduct") { where("product/sku": "widget") }
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

        # The blanket refusal above already catches this unconditionally;
        # pinned separately so a future loosening of that refusal (e.g.
        # teaching entity queries to follow a hop) can't reopen this gap.
        it "refuses a hop where-clause on an entity's own query through an aggregate the chapter never declares" do
          expect do
            build_bluebook("PieceHopUndeclared") do
              aggregate "Board" do
                identified_by :tag
                attribute :tag, BoardTag
                value_object("BoardTag") { attribute :value, String }

                entity "Card" do
                  identified_by :sequence
                  attribute :sequence, Integer
                  reference_to Nonexistent

                  query("ForNonexistent") { where("nonexistent/sku": "widget") }
                end
              end
            end
          end.to raise_error(Malformed,
                             %r{Board::Card\.ForNonexistent asks about nonexistent/sku, which hops through Card's own reference})
        end

        it "refuses a hop whose tail lands on a value object rather than a scalar" do
          # A bare tail landing on a value object ("client.balance") is
          # fine; a second dotted level landing on a nested value object
          # (Box -> Price) is what refuses.
          client = proc do
            value_object("Price") { attribute :cents, Integer }
            value_object("Box")   { attribute :price, Price }
            attribute :box, Box
          end

          expect do
            build_hop_bluebook(client: client) do
              query("Bad") { where("client/box.price": { gt: 500 }) }
            end
          end.to raise_error(Malformed,
                             /hops to Client and then asks about box\.price, which lands on a value object, not a scalar/)
        end

        it "refuses an ordered comparator on a hop's tail when it holds no number" do
          expect do
            build_hop_bluebook do
              query("Bad") { where("client/status": { gt: "active" }) }
            end
          end.to raise_error(Malformed,
                             %r{
                               compares\ client/status\ with\ gt\ after\ hopping\ to\ Client
                               .*
                               is\ the\ lifecycle\ field,\ which\ holds\ text
                             }mx)
        end

        it "refuses an ordered comparator on a hop's tail that's a real attribute holding no number" do
          expect do
            build_hop_bluebook(client: proc { attribute :note, String }) do
              query("Bad") { where("client/note": { gt: "z" }) }
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
              query("AwaitingReply") { where("engagement/client/status": "active") }
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
                query("GrandparentLabel") { where("parent/parent/label": "root") }
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
                nine = ((["node"] * 9) + ["label"]).join("/")
                query("TooFar") { where(nine.to_sym => "root") }
              end
            end
          end.to raise_error(Malformed, /whose hop chain reaches 8 references deep/)
        end

        # `/` crosses into another record, `.` walks fields inside this
        # one (ADR 0025) — the operator alone decides, regardless of what
        # the reference is named (`as: :studio`).
        it "a dot onto a reference attribute never hops — it dead-ends the same way any dotted path onto a " \
           "non-value-object does" do
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
                query("Bad") { where("studio.name": "x") }
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
              query("Good") { where("studio/name.value": "x") }
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
      # Both assertions must reflect the real `Reference`, not a same-
      # named string; `reference_to` mints the bare name `customer`,
      # never `customer_id` (ADR 0025).
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
      mutation = build_command("CmdSetArg") do
        attribute :new_status, Tag
        sets :status, to: :new_status
      end.mutations.first

      expect([mutation.target, mutation.op]).to eq([:status, :set])
      expect(mutation.to_h[:source]).to eq(kind: "argument", name: "new_status")
    end

    it "sets to: anything else is a literal" do
      mutation = build_command("CmdSetLit") { sets :status, to: "sold" }.mutations.first
      expect(mutation.to_h[:source]).to eq(kind: "literal", value: "sold")
    end

    # Covers `sets`'s unset-sentinel rewrite: `to: false` reads as a real
    # value, not absent, and a bare positional second argument is boolean
    # shorthand for `to:`.
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
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /tries to set and remove/)
    end

    # `delegates_to` is an aggregate-level command's synchronous, single-
    # dispatch handoff into one nested entity command, recorded as a
    # `:delegate`-op Mutation. These specs cover the DSL surface only.
    it "delegates_to records a :delegate mutation naming the target and the field map" do
      mutation = build_command("CmdDelegate") { delegates_to "Piece.Move", with: { id: :id, to: :to } }.mutations.first

      # `target` reads back a Symbol through the ordinary DSL word-
      # dispatch path, the same shape every other mutation's `target`
      # already is — worth pinning rather than asserting the wrong type.
      expect([mutation.target.to_s, mutation.op]).to eq(["Piece.Move", :delegate])
      expect(mutation.to_h[:fields]).to eq(id: ":id", to: ":to")
    end

    it "delegates_to refuses a target that does not name an entity and a command" do
      expect { build_command("CmdDelegateBadTarget") { delegates_to "JustAnEntity" } }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /does not name an entity and a command/)
    end

    it "delegates_to refuses sharing a command with its own sets/emits — a pure passthrough only" do
      expect do
        build_command("CmdDelegateNotPure") do
          delegates_to "Piece.Move", with: { id: :id }
          emits "SomethingElseToo"
        end
      end.to raise_error(Hecks::Bluebook::DSL::Malformed, /pure passthrough/)
    end

    # `corrects` declares what past event a command amends, the append-
    # only answer to retroactive correction, recorded as a `:corrects`-op
    # Mutation. These specs cover the DSL surface only.
    it "corrects records a :corrects mutation naming the event and the reason" do
      # `seal_correction_targets` refuses a `corrects` naming an event
      # nothing in the aggregate emits, so this needs a sibling command
      # that really emits it.
      aggregate = build_aggregate("CmdCorrects") do
        command("Happen") { emits "SomethingHappened" }
        command("Fix") { corrects "SomethingHappened", as: :original, reason: "it was wrong" }
      end
      mutation = aggregate.commands.find { |c| c.hecks_name == "Fix" }.mutations.first

      expect([mutation.target.to_s, mutation.op]).to eq(["SomethingHappened", :corrects])
      expect(mutation.source).to eq(as: "original", reason: "it was wrong", reverses: false)
    end

    it "corrects refuses a blank reason — an audit trail needs to say why" do
      expect { build_command("CmdCorrectsNoReason") { corrects "SomethingHappened", reason: "  " } }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /names no reason/)
    end

    # `state(:field)` — the record's own value as a source, never an
    # argument: nothing is imported onto the command, and the wire
    # spelling round-trips (`Literal::StateRef`).
    it "sets append: state(:field) copies the owner's own field into the element" do
      command  = build_command("Snapshot") { sets :parts, append: { value: state(:lives) } }
      mutation = command.mutations.first
      expect(mutation.source[:value]).to eq(Hecks::StateRef.new(:lives))
      expect(command.attributes.map(&:name)).to be_empty
      expect(Hecks::Literal.read(Hecks::Literal.render(mutation.source[:value]))).to eq(Hecks::StateRef.new(:lives))
    end

    it "sets to: state(:field) classifies as a state source on the wire" do
      mutation = build_command("Copy") { sets :status, to: state(:balance) }.mutations.first
      expect(mutation.to_h[:source]).to eq(kind: "state", name: "balance")
    end

    it "refuses state(:field) naming a field the owner does not declare" do
      expect { build_command("Ghost") { sets :parts, append: { value: state(:nope) } } }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /reads state\(:nope\), which the owner does not declare/)
    end

    it "sets append: pushes a built value object onto a list" do
      mutation = build_command("CmdAppend") { sets :parts, append: { size: :size } }.mutations.first

      expect([mutation.target, mutation.op]).to eq([:parts, :append])
      expect(mutation.to_h[:fields]).to eq(size: ":size")
    end

    it "sets increment: reads a command argument to add" do
      mutation = build_command("CmdInc") do
        attribute :amount, Size
        sets :balance, increment: :amount
      end.mutations.first

      expect([mutation.target, mutation.op]).to eq([:balance, :increment])
      expect(mutation.to_h[:source]).to eq(kind: "argument", name: "amount")
    end

    it "sets decrement: takes a literal amount away" do
      mutation = build_command("CmdDec") { sets :lives, decrement: 1 }.mutations.first

      expect([mutation.target, mutation.op]).to eq([:lives, :decrement])
      expect(mutation.to_h[:source]).to eq(kind: "literal", value: 1)
    end

    # A bare `sets :field` (ADR 0025) already says the command accepts
    # that argument; if the command has no local `attribute :field`, it
    # imports the owner's already-declared attribute verbatim.
    it "sets :field with no local attribute imports the owner's own attribute, verbatim" do
      command = build_command("CmdImplicitAttr") { sets :balance }

      expect(command.attribute(:balance).type).to eq("Size")
    end

    # An explicit local attribute is checked first
    # (`resolve_implicit_attributes!`), so a command narrowing or
    # retyping its own argument still wins over the owner's.
    it "an explicit local attribute still shadows the owner's own, rather than being clobbered" do
      command = build_command("CmdShadowAttr") do
        attribute :balance, Tag
        sets :balance
      end

      expect(command.attribute(:balance).type).to eq("Tag")
    end

    # A literal that spells the field's own name is not the shorthand:
    # `sets :moved, to: "moved"` is a value, not a bare-symbol self-
    # reference, so it must not import the owner's attribute.
    it "sets :field, to: \"field\" — a literal spelling the field's name — imports nothing" do
      command = build_command("CmdLiteralSpellsName") { sets :balance, to: "balance" }

      expect(command.attribute(:balance)).to be_nil
      expect(command.mutations.first.to_h[:source]).to eq(kind: "literal", value: "balance")
    end

    # `to: :symbol` naming something the command never declares is a
    # typo, refused at command build time
    # (`refuse_unknown_argument_sources!`), not silently left nil forever.
    it "sets to: a symbol naming no declared attribute refuses at command build time, not silently forever nil" do
      expect { build_command("CmdUnknownRemap") { sets :status, to: :nonexistent_arg } }
        .to raise_error(Hecks::Bluebook::DSL::Malformed,
                        /resolves :nonexistent_arg from its arguments, but Do declares no nonexistent_arg attribute/)
    end

    # When neither the command nor the owner declares the field a bare
    # `sets` names, nothing is imported; the refusal surfaces one level
    # up, at `AggregateBuilder#seal_mutation_targets`.
    it "sets a field neither the command nor the owner declares still refuses, at aggregate build time" do
      expect { build_command("CmdUnresolvedSets") { sets :nonexistent } }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /never declares/)
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
          attribute :thing_id, Hecks::Bluebook::Reference.new("Thing")
          emits "Received"
        end
      end

      expect(port.operation("Receive").hecks_name).to eq("Receive")
    end

    # The driven half, reached through the same `port` call, registered
    # the same way `Hecks.port`'s top-level method registers one
    # (`registry.ports`, not the aggregate's own IR).
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

    # Proves `DomainPortBuilder`'s bare-verb fallback produces a `Port`
    # byte-identical to `PortBuilder`'s. `signal :effect` and `answers`
    # are real corpus uses, not hypothetical ones.
    it "signal builds the same Port PortBuilder itself would, non-default value included" do
      via_domain_port = Hecks::Bluebook::DSL::DomainPortBuilder.build("projection") do
        verb "projected_by"
        signal :effect
      end
      via_port_builder = Hecks::Bluebook::DSL::PortBuilder.build("projection") do
        verb "projected_by"
        signal :effect
      end

      expect(via_domain_port).to be_a(Hecks::Bluebook::Port)
      expect(via_domain_port.to_h).to eq(via_port_builder.to_h)
      expect(via_domain_port.signal).to eq(:effect)
    end

    it "answers builds the same Port PortBuilder itself would" do
      via_domain_port = Hecks::Bluebook::DSL::DomainPortBuilder.build("extraction") do
        verb "extracted_by"
        signal :reply
        answers :canonical
      end
      via_port_builder = Hecks::Bluebook::DSL::PortBuilder.build("extraction") do
        verb "extracted_by"
        signal :reply
        answers :canonical
      end

      expect(via_domain_port).to be_a(Hecks::Bluebook::Port)
      expect(via_domain_port.to_h).to eq(via_port_builder.to_h)
      expect(via_domain_port.answers).to eq([:canonical])
    end

    it "refuses a port declaring both a verb and operations" do
      expect do
        build_domain_port do
          verb "opened_by"
          operation("Receive") do
            attribute :thing_id, Hecks::Bluebook::Reference.new("Thing")
            emits "Received"
          end
        end
      end.to raise_error(Hecks::Bluebook::DSL::Malformed, /declares both a verb and operations/)
    end

    it "answers_query binds a query to the port, and says nothing of the shape its answer takes" do
      port = build_domain_port { answers_query "Census" }

      expect(port.answer_for("Census")).to have_attributes(name: "Census")
      expect(port.to_h).to include(answered_queries: [{ name: "Census" }])
    end

    it "answers_query refuses the shape: it once took, and a query bound twice" do
      expect { build_domain_port { answers_query "Census", shape: :rows } }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /shape/)
      expect do
        build_domain_port do
          answers_query "Census"
          answers_query "Census"
        end
      end.to raise_error(Hecks::Bluebook::DSL::Malformed, /binds Census twice/)
    end

    it "refuses a port with no verb and no operations" do
      expect { build_domain_port {} }.to raise_error(Hecks::Bluebook::DSL::Malformed, /declares no verb and no operations/)
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

    it "keeps routing out of the operation's declared attributes" do
      operation = build_operation do
        emits "Done"
      end

      expect(operation.attributes).to be_empty
    end

    it "refuses behavioral reference_to with receiver and fact guidance" do
      expect do
        build_operation do
          reference_to Thing
          emits "Done"
        end
      end.to raise_error(Hecks::Bluebook::DSL::Malformed, /behavioral routing.*to:.*attribute/)
    end

    it "attribute adds a payload field without a receiver field" do
      operation = build_operation do
        attribute :amount, Integer
        emits "Done"
      end

      expect(operation.attribute(:amount).type).to eq("Integer")
    end

    it "emits records the event the operation announces" do
      operation = build_operation do
        emits "Done"
      end

      expect(operation.emits).to eq(["Done"])
    end

    it "allows an operation with no payload when routing supplies the receiver" do
      expect(build_operation { emits "Done" }.attributes).to be_empty
    end

    it "refuses an operation with no emits" do
      expect do
        build_operation {}
      end.to raise_error(Hecks::Bluebook::DSL::Malformed, /declares no emits/)
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

    it "declares the database and persistence adapter every chapter defaults to" do
      registry = in_registry do
        Hecks.world("Valued") do
          default_database "postgres://localhost/valued"
          default_adapter "PostgresEra"
        end
      end

      expect(registry.world("Valued").to_h)
        .to include(default_database: "postgres://localhost/valued", default_adapter: "PostgresEra")
    end

    it "leaves both defaults undeclared when the world names neither" do
      registry = in_registry { Hecks.world("Plain") { realm "Acme" } }

      expect(registry.world("Plain").to_h).to include(default_database: nil, default_adapter: nil)
    end

    it "refuses a default database that says nothing" do
      expect { in_registry { Hecks.world("Blank") { default_database "" } } }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /default database says something/)
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
      namespace = Hecks::Bluebook::DSL::BindingProxy.namespace("Dom", collector)
      expect(namespace::Anything).to be_a(Hecks::Bluebook::DSL::BindingProxy)
    end

    it "method_missing records a bind for any how-verb" do
      namespace = Hecks::Bluebook::DSL::BindingProxy.namespace("Dom", collector)
      namespace::Thing.invented_by("Someone")

      bind = collector.first
      expect([bind.aggregate, bind.verb, bind.adapter]).to eq(["Dom::Thing", "invented_by", "Someone"])
    end

    it "respond_to_missing? agrees that it answers to anything" do
      proxy = Hecks::Bluebook::DSL::BindingProxy.new("Dom::Thing", collector)
      expect(proxy).to respond_to(:any_verb_at_all)
    end

    it "to_s is the fully-qualified aggregate it stands for" do
      proxy = Hecks::Bluebook::DSL::BindingProxy.new("Dom::Thing", collector)
      expect(proxy.to_s).to eq("Dom::Thing")
    end

    it "bind_for finds the wiring for an aggregate and verb" do
      registry = in_registry { Hecks.hecksagon("Findable") { Findable::Thing.posted_by("Carrier") } }
      hecksagon = registry.hecksagon("Findable")

      expect(hecksagon.bind_for("Thing", "posted_by").adapter).to eq("Carrier")
      expect(hecksagon.bind_for("Thing", "charged_by")).to be_nil
    end
  end

  describe "the world's settings collector" do
    it "respond_to_missing? agrees that any key is a setting" do
      collector = Hecks::Bluebook::DSL::SettingsCollector.new
      expect(collector).to respond_to(:anything_at_all)
    end

    it "to_h returns the collected values" do
      collector = Hecks::Bluebook::DSL::SettingsCollector.new
      collector.instance_eval { office "EC1" }
      expect(collector.to_h).to eq(office: "EC1")
    end
  end

  describe "the const shim" do
    it "is inert outside a load, so an ordinary typo still raises" do
      expect(Hecks::Bluebook::DSL::ConstShim).not_to be_active
      expect { NoSuchConstantAnywhere }.to raise_error(NameError)
    end

    it "resolves unknown constants while a load is running, and restores after" do
      seen = nil
      Hecks::Bluebook::DSL::ConstShim.with(->(name) { "resolved:#{name}" }) do
        seen = SomeUndefinedType
        expect(Hecks::Bluebook::DSL::ConstShim).to be_active
      end

      expect(seen).to eq("resolved:SomeUndefinedType")
      expect(Hecks::Bluebook::DSL::ConstShim).not_to be_active
    end
  end
end
