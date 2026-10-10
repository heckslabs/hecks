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

  # Builds through `build_<builder>` and expects the declaration to be refused with `message`.
  def expect_refusal(builder, name, message, error = Hecks::Bluebook::DSL::Malformed, &body)
    expect { send(:"build_#{builder}", name, &body) }.to raise_error(error, message)
  end

  # One declaration block that replays each of `parts` (blocks) in order.
  def composed(*parts)
    proc { parts.each { |part| instance_eval(&part) } }
  end

  def expect_refusal_in_registry(message, error = Hecks::Bluebook::DSL::Malformed, &body)
    expect { in_registry(&body) }.to raise_error(error, message)
  end

  def hecksagon_of(name, &body)
    in_registry { Hecks.hecksagon(name, &body) }.hecksagon(name)
  end

  def translating(&body)
    in_registry { Hecks.data_translation("Translated", from: "1", to: "2", &body) }.translations.first
  end

  def world_of(name, &body)
    in_registry { Hecks.world(name, &body) }.world(name)
  end

  # A registry holding a chapter with one aggregate, "Thing", and the hecksagon `wiring`
  # (a block) declares over it.
  def thing_registry(name, &wiring)
    in_registry do
      Hecks.bluebook(name) do
        aggregate("Thing") do
          identified_by :thing_id
        end
      end
      Hecks.hecksagon(name, &wiring)
    end
  end

  def expect_translation_refusal(message, error = Hecks::Bluebook::DSL::Malformed, &body)
    expect { translating(&body) }.to raise_error(error, message)
  end

  describe "Hecks" do
    it ".with_registry collects declarations, and restores the previous one", :aggregate_failures do
      registry = in_registry { Hecks.bluebook("WithReg") { vision "v" } }

      expect(registry.bluebook("WithReg").vision).to eq("v")
      expect(Hecks.current_registry).to be_nil
    end

    it ".bluebook registers a domain" do
      expect(build_bluebook("Registered").name).to eq("Registered")
    end

    it ".bluebook records an optional domain version" do
      registry = in_registry { Hecks.bluebook("Registered", version: "v2") { nil } }
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

    def default_bound_hexagon
      hecksagon_of("Hexed") do
        posted_by "Carrier"
        Hexed::Thing.posted_by("SpecialCarrier")
      end
    end

    it ".hecksagon registers a domain-level default bind, applied to every aggregate that doesn't override it" do
      default_bind = default_bound_hexagon.binds.find { |b| b.aggregate.nil? }

      expect([default_bind.aggregate, default_bind.verb, default_bind.adapter]).to eq([nil, "posted_by", "Carrier"])
    end

    it ".hecksagon's domain-level default bind yields to an aggregate-specific bind" do
      expect(default_bound_hexagon.bind_for("Thing", "posted_by").adapter).to eq("SpecialCarrier")
    end

    it ".hecksagon's domain-level default bind covers an aggregate with no bind of its own" do
      expect(default_bound_hexagon.bind_for("OtherThing", "posted_by").adapter).to eq("Carrier")
    end

    def subscribing_hexagon
      hecksagon_of("Hexed") do
        Hexed::Thing.posted_by("Carrier")
        subscribe "OutsideEventHappened"
        subscribe "AnotherOutsideEvent"
      end
    end

    it ".hecksagon registers subscriptions, taken from outside the domain's own bluebook" do
      expect(subscribing_hexagon.subscriptions).to eq(["OutsideEventHappened", "AnotherOutsideEvent"])
    end

    def attaching_registry
      in_registry do
        Hecks.hecksagon("Hexed") do
          attaches "Governance"
          Hexed::Thing.posted_by("Carrier")
        end
      end
    end

    it ".hecksagon's attaches loads a framework member into the same registry", :aggregate_failures do
      registry = attaching_registry

      expect(registry.bluebook("Governance")).not_to be_nil
      expect(registry.bluebook("Governance").aggregate("RoleAssignment")).not_to be_nil
      expect(registry.hecksagon("Hexed").member_chapters).to eq(["Governance"])
    end

    it ".hecksagon's bounded marks this chapter as a bounded context" do
      hecksagon = hecksagon_of("Hexed") do
        bounded
        Hexed::Thing.posted_by("Carrier")
      end

      expect(hecksagon.bounded?).to be true
    end

    it ".hecksagon's attaches ... from: :vendor records the name and needs a registry root to vendor from" do
      # `in_registry`'s bare `Registry.new` sets no root, so this exercises
      # the real refusal a registry with nowhere to vendor from must
      # raise, not a fixture stand-in for it.
      expect_refusal_in_registry(/needs a registry with a root to vendor from/, Hecks::Runtime::WiringError) do
        Hecks.hecksagon("Hexed") { attaches "payments", from: :vendor }
      end
    end

    def renaming_translation
      translating do
        aggregate("Thing", was: "Widget") do
          rename :cost, to: :amount
          move "price.cents", to: "price_cents"
          convert "kind.label", to: "kind.label", values: { "old" => "new" }
          drop :legacy_note
        end
      end
    end

    it ".data_translation registers the two eras and a rename", :aggregate_failures do
      translation = renaming_translation
      thing = translation.for_aggregate("Thing")

      expect([translation.domain, translation.from, translation.to]).to eq(["Translated", "1", "2"])
      expect([thing.was, thing.renames]).to eq(["Widget", { cost: :amount }])
    end

    it ".data_translation registers a move, a convert, and a drop", :aggregate_failures do
      thing = renaming_translation.for_aggregate("Thing")

      expect(thing.moves.map { |move| [move.from, move.to] }).to eq([["price.cents", "price_cents"]])
      expect(thing.converts.map { |c| [c.from, c.to, c.values] }).to eq([["kind.label", "kind.label", { "old" => "new" }]])
      expect(thing.drops).to eq([:legacy_note])
    end

    it ".data_translation registers a retype" do
      translation = translating { aggregate("Thing") { retype "Money", to: "Cash" } }

      expect(translation.for_aggregate("Thing").retypes.map { |r| [r.from, r.to] }).to eq([["Money", "Cash"]])
    end

    it ".data_translation registers a retired aggregate" do
      expect(translating { retired "Ledger" }.retired).to eq(["Ledger"])
    end

    it ".data_translation registers a compute with its SQL expression" do
      translation = translating do
        aggregate("Thing") { compute "price_cents", to: "price_dollars", sql: "price_cents::numeric / 100" }
      end
      computed = translation.for_aggregate("Thing").computes.first

      expect([computed.from, computed.to, computed.sql]).to eq(["price_cents", "price_dollars", "price_cents::numeric / 100"])
    end

    it ".data_translation registers a rekey with its SQL expression" do
      translation = translating { aggregate("Thing") { rekey sql: "(__s ->> 'email')" } }

      expect(translation.for_aggregate("Thing").rekeys.first.sql).to eq("(__s ->> 'email')")
    end

    it ".data_translation refuses a rekey with no sql:" do
      expect_translation_refusal(/needs its sql: expression/) { aggregate("Thing") { rekey sql: "" } }
    end

    it ".data_translation registers a backfill with its default value" do
      translation = translating { aggregate("Thing") { backfill :tier, default: "standard" } }
      backfilled = translation.for_aggregate("Thing").backfills.first

      expect([backfilled.name, backfilled.default]).to eq([:tier, "standard"])
    end

    it ".data_translation refuses a backfill with no default:" do
      expect_translation_refusal(/needs a default: value/) { aggregate("Thing") { backfill :tier, default: nil } }
    end

    it ".data_translation refuses an unresolved placeholder" do
      expect_translation_refusal(/leaves :cost unresolved/) { aggregate("Thing") { unresolved :cost, candidates: [:amount] } }
    end

    # A typo admitted nowhere in the grammar falls through to Ruby's own
    # NoMethodError, not a DSL-level Malformed.
    it ".data_translation falls through to NoMethodError for a typo admitted nowhere in the grammar" do
      expect_translation_refusal(/renmae/, NoMethodError) { aggregate("Thing") { renmae :cost, to: :amount } }
    end

    # A word legal elsewhere (Aggregate context) but not inside a
    # TranslationAggregate body still gets WordGate's table-driven
    # refusal, naming this context's legal words.
    it ".data_translation refuses a word admitted elsewhere in the grammar but not here" do
      expect_translation_refusal(/not a word TranslationAggregate admits/) { aggregate("Thing") { identified_by :cost } }
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
    it ".boot loads a domain directory and returns the entry point", :aggregate_failures, :io do
      skip "no reachable Postgres — start one to run this spec" unless PostgresProbe.available?

      runtime = Hecks.boot(File.expand_path("../examples/pizzas", __dir__))
      expect(runtime).to be_a(Hecks::Runtime::Dispatcher)
      expect(runtime.verbs).to include("Pizzas::Order.Purchase")
    end

    # Reads declarations only: no adapter is resolved, so a domain that declares
    # `persisted_by("PostgresEra")` answers without a database.
    it ".describe reads a domain directory, binding no adapter and opening no database", :aggregate_failures do
      described = Hecks.describe(File.expand_path("../examples/pizzas", __dir__))

      expect(described).to be_a(Hecks::Runtime::Loader::Described)
      expect(described.registry.bluebooks.values.map(&:name)).to include("Pizzas")
    end

    it ".boot_described finishes a boot from what describe loaded, reading nothing again" do
      described = Hecks.describe(File.expand_path("../examples/banking", __dir__))

      runtime = Hecks.boot_described(described, install_driving: false)

      expect(runtime.registry).to be(described.registry)
    end

    it ".boot refuses a declaration loaded outside a boot" do
      expect { Hecks.bluebook("Orphan") { vision "x" } }
        .to raise_error(Hecks::LoadOutsideBoot, /outside a boot/)
    end

    def boot_pizza_files
      root = File.expand_path("../examples/pizzas", __dir__)
      files = [File.join(root, "bluebook/pizzas.bluebook"), File.join(root, "pizzas_behaviors.hecksagon")]
      Hecks.boot_files(files, install_driving: false)
    end

    # `.boot_files` is the explicit-file sibling of `.boot`, Memory-
    # persisted so it needs no Postgres. Files are named exactly, not
    # discovered by globbing a directory.
    it ".boot_files loads exactly the files named, in place", :aggregate_failures do
      runtime = boot_pizza_files

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

    def unnamed_attribute_declaration
      proc do
        value_object("Label") { attribute :value, String }
        begin
          attribute "", Object.const_get("Label")
        rescue StandardError
          attribute "", :Label
        end
      end
    end

    it "refuses an unnamed attribute" do
      # a declared value-object type, so the value-object-types rule does not
      # fire first and mask the naming rule this example is about
      expect_refusal(:aggregate, "Nameless", /an attribute is named/, &unnamed_attribute_declaration)
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
    def self_rooted_entity_command
      proc do
        aggregate "Root" do
          attribute :key, Key
          value_object("Key") { attribute :value, String }

          entity("Child") { command("Change") { reference_to Child } }
        end
      end
    end

    it "refuses an entity command that names itself as its root" do
      message = "an entity command is addressed through its aggregate; " \
                "Root.Child.Change names itself as its root"
      expect_refusal(:bluebook, "HeadOnly", message, &self_rooted_entity_command)
    end

    # A command's reference argument is offered to the meta-domain as the
    # head's own id, so resolution failure names which id it looked for.
    def reference_to_value_object
      proc do
        aggregate "Root" do
          identified_by :id

          value_object("Code") { attribute :value, String }

          command("UseCode") { reference_to Code }
        end
      end
    end

    it "refuses a reference to a value object rather than an aggregate head" do
      message = /UseCode#attributes\[0\]: no Aggregate with bluebook, name "HeadOnly:Code"/
      expect_refusal(:bluebook, "HeadOnly", message, &reference_to_value_object)
    end

    # A default must fill the shape it's declared on: `default: "open"` on
    # a value-object attribute built cleanly but refused every create at
    # dispatch — refusing consistently is agreement about nothing.
    it "refuses a bare default where the type wants fields" do
      expect_refusal(:aggregate, "Defaulted", /Cover is a value object — a default fills its FIELDS/) do
        value_object("Cover") { attribute :value, String }
        attribute :cover, Cover, default: "open"
      end
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
    def label_declared_twice
      proc do
        value_object("Tag") { attribute :value, String }
        value_object("Size") { attribute :value, Integer }
        attribute :label, Tag
        attribute :label, Size
      end
    end

    it "refuses an attribute name declared twice" do
      expect_refusal(:aggregate, "DupAttr", /label is declared twice/, &label_declared_twice)
    end

    def colliding_relationship
      proc do
        aggregate("Account") { identified_by { attribute :number, String } }

        aggregate "Portfolio" do
          identified_by { attribute :number, String }
          attribute :account, String
          belongs_to Account
        end
      end
    end

    it "refuses a relationship whose name collides with an existing attribute" do
      expect_refusal(:bluebook, "DupRelationship", /account is declared twice/, &colliding_relationship)
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

    def ensured_command
      build_command("Ensured") do
        ensures("it landed") { old.balance.cents <= balance.cents }
      end
    end

    it "carries an ensures as canonical text beside the givens", :aggregate_failures do
      # The postcondition rides the same Rule shape preconditions do —
      # extracted, canonicalised, serialized — and `old` is just a word
      # in the text until enforcement resolves it.
      spelled = ensured_command

      expect(spelled.ensures.map(&:canonical)).to eq(["old.balance.cents <= balance.cents"])
      expect(spelled.to_h[:ensures].size).to eq(1)
    end

    it "serializes an ensures with its description, canonical text and structured form", :aggregate_failures do
      row = ensured_command.to_h[:ensures].first

      expect(row).to include(description: "it landed", canonical: "old.balance.cents <= balance.cents")
      # The structured form rides beside the text, derived from it.
      expect(row[:ast]).to eq(Hecks::Bluebook::Expression::AstJson.emit_predicate(row[:canonical]))
    end

    def needing_command
      build_command("Stamped") do
        attribute :now, Instant
        needs :now
      end
    end

    it "records a needed outside fact on the command and in its IR", :aggregate_failures do
      needing = needing_command

      expect(needing.needs).to eq([:now])
      expect(needing.to_h[:needs]).to eq([{ fact: "now" }])
    end

    it "carries no needs on a command that names none" do
      expect(build_command("Plain") { emits "Done" }.to_h[:needs]).to eq([])
    end

    it "refuses a fact the runtime cannot supply" do
      expect_refusal(:command, "Weathered", /cannot supply/) do
        attribute :weather, Instant
        needs :weather
      end
    end

    it "refuses a need declared twice" do
      expect_refusal(:command, "Twice", /twice/) do
        attribute :now, Instant
        needs :now
        needs :now
      end
    end

    it "refuses a need with no attribute of that name to fill" do
      expect { build_command("Unfilled") { needs :now } }
        .to raise_error(Malformed, /declares no attribute :now/)
    end

    it "sets alone, with no operation named at all, means to: the same field — the omittable case", :aggregate_failures do
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

    def lookahead_policy
      proc do
        policy "Echo" do
          on      "Started"
          where { name.match?(/(?=x)/) }
          trigger "Thing.Next"
        end
      end
    end

    it "refuses a .match? pattern outside PatternSubset in a policy where too" do
      message = /Echo's where matches against "\(\?=x\)", which uses a lookahead/
      expect_refusal(:bluebook, "Watched", message, &lookahead_policy)
    end

    # A method call the expression language has no node for parses as a lookup of an attribute that
    # can never exist. It is refused where the rule is built, not on the first dispatch.
    describe "a call the expression language does not support" do
      def status_code_invariant
        proc do
          value_object("StatusCode") do
            attribute :value, Integer
            invariant("an http status code is a real one") { value.between?(100, 599) }
          end
        end
      end

      def ranged_policy
        proc do
          policy "Echo" do
            on      "Started"
            where { count.between?(1, 9) }
            trigger "Thing.Next"
          end
        end
      end

      def supported_spellings
        proc do
          given("the balance is positive") { balance.positive? }
          # rubocop:disable-next Style/ComparableBetween
          given("the balance is a real one") { balance >= 100 && balance <= 599 }
          given("the tag is named") { !status.to_s.empty? }
          given("the tag is one of these") { ["a", "b"].include?(status) }
        end
      end

      it "is refused in a value object invariant, naming the expression and the alternative" do
        message = a_string_including(
          %(StatusCode's invariant "an http status code is a real one" uses "value.between?(100, 599)"),
          "value >= 100 && value <= 599"
        )

        expect { build_aggregate("Statuses", &status_code_invariant) }.to raise_error(Malformed, message)
      end

      it "is refused in a given" do
        expect do
          build_command("Ranged") do
            given("the size is small") { balance.between?(1, 9) }
          end
        end.to raise_error(Malformed, /Do's given "the size is small" uses "balance\.between\?\(1, 9\)"/)
      end

      it "is refused in a policy where" do
        expect_refusal(:bluebook, "Watched", /Echo's where uses "count\.between\?\(1, 9\)"/, &ranged_policy)
      end

      it "does not refuse a bare .nil?, which real bluebooks already declare and which loads" do
        expect do
          build_command("Nilable") do
            given("the tag is assigned") { !status.nil? }
          end
        end.not_to raise_error
      end

      it "leaves the supported spellings alone" do
        expect { build_command("Supported", &supported_spellings) }.not_to raise_error
      end
    end

    it "refuses writing one field twice in a command — effects are one update set, not a sequence" do
      expect_refusal(:command, "Twice", /Do writes status twice \(set and set\)/) do
        sets :status, to: "open"
        sets :status, to: "closed"
      end
    end

    it "then_set is gone — sets is the word now (ADR 0025 reverts the rename)" do
      # `then_set` is reachable only as frozen era text through
      # EraGuard.shadow_parse (Syntax::Keyword carries it as `was:`), never
      # as live syntax.
      expect { build_command("Spelled2") { then_set :balance, increment: :amount } }
        .to raise_error(Malformed, "Do's then_set is gone — sets is the word now")
    end

    it "refuses a command that names its own root twice" do
      expect_refusal(:command, "Confused", /acts on ONE/) do
        reference_to "Thing"
        reference_to "Thing"
      end
    end

    it "refuses a command that declares role twice" do
      expect_refusal(:command, "DoubleRole", /role twice/) do
        role "Teller"
        role "Branch manager"
      end
    end

    def unreadable_given
      proc do
        aggregate("Thing") do
          command("Do") { given("unreadable", &eval("proc { 1 < 2 }")) } # rubocop:disable Style/EvalWithLocation -- deliberately WITHOUT file/line: this fixture exercises the "source could not be read" refusal, which needs an untraceable source_location
        end
      end
    end

    it "refuses a given whose source could not be read" do
      expect_refusal(:bluebook, "Unreadable", /did not survive extraction/, &unreadable_given)
    end

    def currency_members
      proc do
        attribute :code,        String
        attribute :minor_units, Integer

        member code: "USD", minor_units: 2
        member code: "JPY", minor_units: 0
      end
    end

    def coin_aggregate
      members = currency_members
      proc do
        aggregate("Coin") do
          identified_by :id

          attribute :currency, Currency

          value_object("Currency", &members)
        end
      end
    end

    def coins_currency
      in_registry { Hecks.bluebook("Coins", &coin_aggregate) }.bluebooks["Coins"].aggregates.first.value_objects.first
    end

    it "bare member lines declare a closed set of members, in declaration order" do
      expect(coins_currency.members).to eq([{ code: "USD", minor_units: 2 }, { code: "JPY", minor_units: 0 }])
    end

    # `to_h` must preserve a member field's declared type (e.g. an Integer
    # stays an Integer), not stringify it — indistinguishable otherwise
    # from a value some row spelled as text.
    it "to_h preserves a member field's own declared type, not just its String spelling" do
      expect(coins_currency.to_h[:members]).to eq(
        [[["code", "USD"], ["minor_units", 2]], [["code", "JPY"], ["minor_units", 0]]]
      )
    end

    it "refuses an empty member" do
      expect_refusal(:bluebook, "Empty", /empty member/) { aggregate("Thing") { value_object("V") { member } } }
    end

    def inline_one_of_aggregate
      build_aggregate("Inline") { attribute :status, one_of("open", "shut") }
    end

    it "desugars an inline one_of into a value object named for the attribute", :aggregate_failures do
      # Desugaring keeps the closed set closed; a plain String attribute
      # would let the set mean nothing.
      aggregate = inline_one_of_aggregate
      status = aggregate.attributes.find { |a| a.name == :status }

      expect(status.type).to eq("Status")
      expect(aggregate.value_object("Status").members).to eq([{ value: "open" }, { value: "shut" }])
    end

    it "keeps the desugared one_of a closed set" do
      expect(inline_one_of_aggregate.value_object("Status").closed_set?).to be(true)
      # enforcement is the ordinary one_of machinery from here on — the same
      # Value.admit_member path spec/one_of_spec already pins for the block form
    end

    it "refuses the scalar one_of spelling rather than dropping it" do
      expect_refusal(:bluebook, "Scalar", /names no values/) { aggregate("Thing") { value_object("V") { one_of } } }
    end
  end

  describe "value-object-typed attributes" do
    def holding_value_objects
      proc do
        value_object("Kind") do
          attribute :name, String
          invariant("current or savings") { ["current", "savings"].include?(name) }
        end

        value_object("Amount") do
          attribute :cents,    Integer
          attribute :currency, String
        end
      end
    end

    def holding_open_command
      proc do
        command("Open") do
          attribute :kind,   Kind
          attribute :amount, Amount
        end
      end
    end

    def holding_declaration
      parts = [holding_value_objects, holding_open_command]
      proc do
        aggregate("Holding") do
          # A bare scalar id short-circuits the `.value` dig
          # (`identity_from`), so this derives from exactly what dispatch
          # supplies — nothing minted.
          identified_by :id

          attribute :kind,   Kind
          attribute :amount, Amount
          parts.each { |part| instance_eval(&part) }
        end
      end
    end

    def account_domain
      declaration = holding_declaration
      in_registry do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)

        Hecks.bluebook("Coerced", &declaration)
        Hecks.hecksagon("Coerced") { Coerced::Holding.persisted_by("Memory") }
      end
    end

    def coerced_runtime
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(account_domain.tap(&:verify!)))
    end

    def open_holding(runtime, id, kind, cents = 100)
      runtime.dispatch_flat("Coerced::Holding.Open", id: id, kind: kind, amount: { cents: cents, currency: "GBP" })
    end

    it "materializes a declared value object rather than a hash", :aggregate_failures do
      state = open_holding(coerced_runtime, "h1", { name: "current" }).state

      expect(state[:kind]).to be_a(Hecks::Runtime::Value)
      expect(state[:kind].type_name).to eq("Kind")
      expect(state[:kind][:name]).to eq("current")
    end

    it "identifies a value object by its declared state", :aggregate_failures do
      runtime = coerced_runtime
      first  = open_holding(runtime, "h1", { name: "current" }, 100).state[:kind]
      second = open_holding(runtime, "h2", { name: "current" }, 250).state[:kind]

      expect(first).to eq(second)
      expect(first.to_h).to eq(name: "current")
    end

    it "enforces the invariant on a value object" do
      runtime = coerced_runtime

      expect { open_holding(runtime, "h2", { name: "offshore" }) }
        .to raise_error(Hecks::Runtime::InvariantViolation, /current or savings/)
    end

    # A bare scalar auto-wraps into a single-field value object's sole
    # attribute (`Value::Coercion#fields_for`); the refusal survives only
    # for a multi-field one like `Amount`, where the scalar can't say
    # which field it means.
    it "refuses a scalar for every multi-field value object" do
      runtime = coerced_runtime

      expect { runtime.dispatch_flat("Coerced::Holding.Open", id: "h3", kind: { name: "current" }, amount: "a lot") }
        .to raise_error(Hecks::Runtime::TypeMismatch, /pass its fields as an object/)
    end
  end

  describe "a bluebook" do
    # Shared fixture for the two correlates_by dot-resolution refusal specs
    # below: `Ref` nests `Amount`, giving `correlates_by` somewhere to run
    # out of scalar.
    def thing_value_objects
      proc do
        value_object("ThingId") { attribute :value, String }
        value_object("Ref") { attribute :amount, Amount }
        value_object("Amount") { attribute :cents, Integer }
      end
    end

    def thing_start_command
      proc do
        command "Start" do
          attribute :id,  ThingId
          attribute :ref, Ref
          emits "Started"
        end
      end
    end

    def ref_amount_declaration
      parts = [thing_value_objects, thing_start_command]
      proc do
        aggregate "Thing" do
          identified_by :id
          attribute :id, ThingId
          parts.each { |part| instance_eval(&part) }
        end
      end
    end

    def build_ref_amount_bluebook(domain_name, &process_manager_block)
      thing = ref_amount_declaration
      build_bluebook(domain_name) do
        instance_eval(&thing)
        process_manager("Broken", &process_manager_block)
      end
    end

    def customer_declaration
      proc do
        aggregate "Customer" do
          identified_by :id

          attribute :reference, CustomerNumber
          value_object("CustomerNumber") { attribute :value, String }
        end
      end
    end

    def portfolio_model
      customer = customer_declaration
      build_bluebook("Portfolio") do
        instance_eval(&customer)
        read_model "CustomerPortfolio" do
          reference_to Customer, as: :reference
          include Customer
          include Account
        end
      end.read_models.first
    end

    it "read_model declares a domain-level projection's names and reference", :aggregate_failures do
      model = portfolio_model

      expect([model.name, model.query_name, model.reference_name, model.reference_target])
        .to eq(["CustomerPortfolio", "customer_portfolio", :reference, "Customer"])
    end

    it "read_model gathers the included aggregate heads" do
      heads = portfolio_model.aggregate_heads

      expect(heads).to eq([{ aggregate: "Customer", as: :customer, many: false },
                           { aggregate: "Account", as: :accounts, many: true }])
    end

    it "report is gone — read_model is the word now (ADR 0025 reverts the rename)" do
      customer = customer_declaration

      expect_refusal(:bluebook, "ReportGone", "report is gone — read_model is the word now") do
        instance_eval(&customer)
        report("CustomerPortfolio") { reference_to Customer, as: :reference }
      end
    end

    def include_first_portfolio
      build_bluebook("EitherWay") do
        read_model("Portfolio") do
          description "a portfolio"
          include Account

          reference_to Customer
        end
      end.read_models.first
    end

    def reference_first_portfolio
      build_bluebook("EitherWay2") do
        read_model("Portfolio") do
          description "a portfolio"
          reference_to Customer
          include Account
        end
      end.read_models.first
    end

    it "gathers includes declared before the reference, in either order" do
      # `many:` compares each include against the reference; includes
      # resolve at build, so declaration order between include and
      # reference doesn't matter.
      expect(include_first_portfolio.aggregate_heads).to eq(reference_first_portfolio.aggregate_heads)
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

    def expect_read_model_refusal(message, &body)
      expect_refusal(:bluebook, "BadModel", message) { read_model("Portfolio", &body) }
    end

    it "refuses an empty read-model description" do
      # a reference, so `needs an aggregate-head reference` does not fire first
      # and mask the description rule this case is about
      expect_read_model_refusal(/a description says something/) do
        reference_to Customer
        description ""
      end
    end

    it "refuses a second reference_to on the same read model" do
      expect_read_model_refusal(/already has a projection reference/) do
        reference_to Customer
        reference_to Account
      end
    end

    it "refuses a duplicate include alias on the same read model" do
      expect_read_model_refusal(/already projects customer/) do
        reference_to Customer
        include Customer, as: :customer
        include Customer, as: :customer
      end
    end

    def portfolio_query_options
      proc do
        where(status: "active")
        order_by :id, :desc
        limit 20
        offset 5
        nulls :last
        authorize :portfolio_access, tenant: :customer_id
        inspect_query :sql
      end
    end

    def queryable_portfolio
      options = portfolio_query_options
      build_bluebook("QueryablePortfolio") do
        read_model "Portfolio" do
          reference_to Customer
          include Account

          instance_eval(&options)
        end
      end.read_models.first
    end

    it "lets read models combine common query options with aggregate-head joins", :aggregate_failures do
      model = queryable_portfolio

      expect(model.wheres.first.to_h).to eq(field: "status", op: "eq", value: '"active"')
      expect(model.aggregate_heads).to eq([{ aggregate: "Account", as: :accounts, many: true }])
    end

    it "lets read models carry an offset and an authorization beside the joins", :aggregate_failures do
      model = queryable_portfolio

      expect(model.offset.to_h).to eq(value: "5")
      expect(model.authorization.to_h).to eq(policy: "portfolio_access", tenant: "customer_id")
    end

    it "read_model refuses cursor at build — no interpreter implements cursor pagination" do
      expect_read_model_refusal(/declares cursor, but no interpreter implements cursor pagination/) do
        reference_to Customer
        include Account

        cursor :after
      end
    end

    def rider_aggregate
      proc do
        aggregate "Rider" do
          identified_by :tag
          attribute :tag, RiderTag
          value_object("RiderTag") { attribute :value, String }
          reference_to Bicycle
        end
      end
    end

    def bicycle_aggregate
      proc do
        aggregate "Bicycle" do
          identified_by :serial
          attribute :serial, BicycleSerial
          value_object("BicycleSerial") { attribute :value, String }
          reference_to Rider
        end
      end
    end

    it "refuses two aggregates that reference each other" do
      message = /reference cycle: (Rider -> Bicycle -> Rider|Bicycle -> Rider -> Bicycle)/
      expect_refusal(:bluebook, "BackAndForth", message, &composed(rider_aggregate, bicycle_aggregate))
    end

    # A ring can close through an owned entity's own `reference_to`, not
    # only a direct aggregate-to-aggregate edge; both must feed the same
    # cycle check.
    def card_entity
      proc do
        entity "Card" do
          identified_by :sequence
          attribute :sequence, Integer
          reference_to Product
        end
      end
    end

    def board_aggregate
      card = card_entity
      proc do
        aggregate "Board" do
          identified_by :tag
          attribute :tag, BoardTag
          value_object("BoardTag") { attribute :value, String }
          instance_eval(&card)
        end
      end
    end

    def product_aggregate
      proc do
        aggregate "Product" do
          identified_by :sku
          attribute :sku, ProductSku
          value_object("ProductSku") { attribute :value, String }
          reference_to Board
        end
      end
    end

    it "refuses a reference cycle that closes through an owned entity" do
      message = /reference cycle: (Board -> Product -> Board|Product -> Board -> Product)/
      expect_refusal(:bluebook, "BackAndForthThroughAPiece", message, &composed(board_aggregate, product_aggregate))
    end

    def owner_aggregate
      proc do
        aggregate "Owner" do
          identified_by :tag
          attribute :tag, OwnerTag
          value_object("OwnerTag") { attribute :value, String }
        end
      end
    end

    def item_aggregate
      proc do
        aggregate "Item" do
          identified_by :serial
          attribute :serial, ItemSerial
          value_object("ItemSerial") { attribute :value, String }
          reference_to Owner
        end
      end
    end

    it "allows one aggregate to reference another in a single direction" do
      bluebook = build_bluebook("OneWay", &composed(owner_aggregate, item_aggregate))

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
      expect(build_bluebook("NeverRenamed") { nil }.to_h).to include(formerly_known_as: nil)
    end

    def notify_policy
      proc do
        policy "NotifyOnPlacement" do
          on      "OrderPlaced"
          trigger Notify::Send
          across  "Notifications"
        end
      end
    end

    it "policy declares a reaction the domain owns rather than one aggregate" do
      reaction = build_bluebook("Reacting", &notify_policy).policies.first

      expect([reaction.name, reaction.on_event, reaction.target_domain])
        .to eq(["NotifyOnPlacement", "OrderPlaced", "Notifications"])
    end

    def checkout_transition
      proc do
        transition "PaymentAuthorized" => "paid", from: "awaiting_payment" do
          dispatch Order::Confirm, with: { order: :order_id }
        end
      end
    end

    def checkout_process_manager
      transition = checkout_transition
      build_bluebook("Converse") do
        process_manager "Checkout" do
          correlates_by :"order.id"
          starts_on "OrderPlaced"
          ends_on   "OrderCompleted"
          instance_eval(&transition)
        end
      end.process_managers.first
    end

    it "process_manager declares a correlated conversation", :aggregate_failures do
      checkout = checkout_process_manager

      expect([checkout.correlates_by, checkout.starts_on]).to eq([:"order.id", "OrderPlaced"])
      # `correlates_by` must cross the wire as the same bare word Symbol
      # readers expect (`value&.to_sym`); a colon-wrapped or stringified
      # spelling would break that round trip.
      expect(checkout.to_h[:correlates_by]).to eq("order.id")
    end

    it "process_manager derives its states from the transitions that name them" do
      # States are derived from the transitions that name them, first-seen
      # order — the same reading `Behaviour::Lifecycle#states` gives an
      # aggregate's own field.
      expect(checkout_process_manager.states).to eq(["awaiting_payment", "paid"])
    end

    it "process_manager keeps what a transition dispatches", :aggregate_failures do
      handler = checkout_process_manager.handler_for("PaymentAuthorized")

      expect([handler.from_state, handler.to_state]).to eq(["awaiting_payment", "paid"])
      expect(handler.dispatches.first.to_h)
        .to eq({ command_name: "Order.Confirm", with_spec: [["order", ":order_id"]], compensates: nil })
    end

    # A process manager built straight from the IR class can carry a nil
    # `correlates_by`, even though the DSL itself always refuses to mint
    # one without it; `to_h` must read back `nil`, not the ambiguous `""`.
    it "a process manager's absent correlates_by survives to_h as nil, not an empty string" do
      expect(Hecks::Bluebook::ProcessManager.new(name: "Untethered").to_h[:correlates_by]).to be_nil
    end

    # Builds a process manager that has already declared its correlation and start, then runs
    # the block inside it, expecting the declaration to be refused.
    def expect_process_manager_refusal(message, &body)
      expect_refusal(:bluebook, "Broken", message, StandardError) do
        process_manager("Broken") do
          correlates_by :"id.value"
          starts_on "Started"
          instance_eval(&body) if body
        end
      end
    end

    it "process_manager refuses a machine with no transitions at all" do
      expect_process_manager_refusal(/declares no transitions/)
    end

    # States are derived from the transitions that name them, so this
    # isn't a transition through an undeclared state — it's a transition
    # naming no from: at all, which no admission check would ever match.
    it "process_manager refuses a transition naming no from: — it would match no instance ever" do
      expect_process_manager_refusal(/names no from:/) { transition("Next" => "b") { dispatch X::Y } }
    end

    # A leg is selected by (event, current state); two from different
    # states are fine, but two from the same state would leave the
    # runtime picking by declaration order, silently.
    it "process_manager refuses two transitions on one event from the same state — the leg would be ambiguous" do
      expect_process_manager_refusal(/declares two transitions on "Next" from "a"/) do
        transition "Next" => "b", from: "a"
        transition "Next" => "c", from: ["z", "a"]
      end
    end

    def relay_process_manager
      build_bluebook("TwoLegs") do
        process_manager "Relay" do
          correlates_by :"id.value"
          starts_on "Started"
          transition "Next" => "b", from: "a"
          transition "Next" => "c", from: "b"
        end
      end.process_managers.first
    end

    it "process_manager accepts two transitions on one event from different states", :aggregate_failures do
      pm = relay_process_manager

      expect([pm.handler_for("Next", "a").to_state, pm.handler_for("Next", "b").to_state]).to eq(%w[b c])
      expect(pm.handler_for("Next", "c")).to be_nil
    end

    def expect_ref_amount_refusal(domain_name, message, &process_manager_block)
      expect { build_ref_amount_bluebook(domain_name, &process_manager_block) }.to raise_error(message)
    end

    it "process_manager refuses correlates_by that resolves to a value object, not a scalar" do
      # `ref.amount` reaches a real field, but that field's type (`Amount`)
      # is itself a value object, not a scalar — the same one-VO-short
      # mistake `identified_by` already refuses on the aggregate side.
      expect_ref_amount_refusal("NonScalarKey", /Amount is a value object, not a scalar/) do
        correlates_by :"ref.amount"
        starts_on "Started"
        transition("Started" => "b", from: "a") { dispatch Thing::Start }
      end
    end

    it "process_manager refuses correlates_by naming a field no emitting command declares that shape for" do
      expect_ref_amount_refusal("StrandedKey", /Ref has no field "currency"/) do
        correlates_by :"ref.currency"
        starts_on "Started"
        transition("Started" => "b", from: "a") { dispatch Thing::Start }
      end
    end

    # `identified_by` reads its own source line via Prism, so it needs a
    # line to itself; sharing a line with the outer block would make
    # `block_node_at` read the wrong source (pre-order walk).
    def agged_bluebook
      build_bluebook("Agged") do
        aggregate("Thing") do
          identified_by :id
        end
      end
    end

    it "aggregate adds an aggregate" do
      expect(agged_bluebook.aggregates.map(&:name)).to eq(["Thing"])
    end

    it "core, supporting and generic each record a classification" do
      %i[core supporting generic].each_with_index do |keyword, index|
        builder = Hecks::Bluebook::DSL::BluebookBuilder.new("Classified#{index}")
        builder.public_send(keyword)
        expect(builder.classification).to eq(keyword)
      end
    end

    def referencing_chapter
      proc do
        aggregate("Referencer") do
          identified_by :id
          given("shared fact")
        end
      end
    end

    def declaring_chapter
      proc do
        aggregate("Declarer") do
          identified_by :id
          given("shared fact") { true }
        end
      end
    end

    def referencing_piece_chapter
      proc do
        aggregate("Referencer") do
          identified_by :id
          entity("Piece") do
            identified_by :id
            given("shared fact")
          end
        end
      end
    end

    def declaring_piece_chapter
      proc do
        aggregate("Declarer") do
          identified_by :id
          entity("Piece") do
            identified_by :id
            given("shared fact") { true }
          end
        end
      end
    end

    # Two separate `Hecks.bluebook` calls under one chapter name — the shape a chapter split
    # across real files takes. The reference is deferred, not refused, until
    # `MetaValidator.judge_deferred!` runs after both have loaded.
    def load_split_chapter(name, *chapters)
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Hecks::Bluebook::MetaValidator.defer { chapters.each { |chapter| Hecks.bluebook(name, &chapter) } }
        Hecks::Bluebook::MetaValidator.judge_deferred!(registry)
      end
      registry
    end

    it "resolve_pending_chapter_givens! resolves a bare chapter-given left pending by an earlier file" do
      registry = load_split_chapter("SplitGiven", referencing_chapter, declaring_chapter)
      referencer = registry.bluebook("SplitGiven").aggregates.find { |a| a.hecks_name == "Referencer" }

      expect(referencer.preconditions.map(&:canonical)).to eq(["true"])
    end

    it "resolve_pending_chapter_entity_givens! resolves a bare entity-level given left pending by an " \
       "earlier file, DECLARED ON A DIFFERENT AGGREGATE'S OWN PIECE" do
      # The entity-scoped analogue, one level down: reference and
      # declaration live on a piece under two different aggregates
      # (Account::LedgerEntry / SafeDepositBox::Visit).
      registry = load_split_chapter("SplitEntityGiven", referencing_piece_chapter, declaring_piece_chapter)
      referencer_piece = registry.bluebook("SplitEntityGiven").aggregates
                                 .find { |a| a.hecks_name == "Referencer" }.entities.first

      expect(referencer_piece.preconditions.map(&:canonical)).to eq(["true"])
    end

    def verbed_bluebook
      build_bluebook("Verbed") do
        aggregate("Thing") do
          identified_by :id
          command("Do")
        end
      end
    end

    it "verbs lists every command as a fully-qualified verb" do
      expect(verbed_bluebook.verbs).to eq(["Verbed::Thing.Do"])
    end

    # An entity-owned command reaches Dispatcher#dispatch through the same
    # dotted-verb routing as an ordinary command, recursing two levels
    # deep because entities can nest inside entities (ADR 0026).
    def piece_entity
      proc do
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

    def nested_bluebook
      piece = piece_entity
      build_bluebook("Nested") do
        aggregate("Thing") do
          identified_by :id
          command("Do")
          instance_eval(&piece)
        end
      end
    end

    it "verbs recurses into entities, arbitrarily deep, as dotted verbs" do
      expect(nested_bluebook.verbs).to contain_exactly(
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

    def identified_by_name
      build_aggregate("Identified") do
        value_object("IdentifiedName") { attribute :value, String }
        attribute :name, IdentifiedName

        identified_by :name
      end
    end

    it "identified_by names a field, and the HEAD is what readers look up", :aggregate_failures do
      identified = identified_by_name

      expect(identified.identity_paths).to eq(["name.value"])
      expect(identified.identified_by).to eq(:name)
    end

    def composite_identity_aggregate
      build_aggregate("Composite") do
        value_object("CompositeName") { attribute :value, String }
        attribute :name, CompositeName

        # `:batch_id` has no matching attribute, resolved bare by the
        # `_id` convention (`resolve_identity_field!`); `:name` unwraps
        # its single-field value object the ordinary way.
        identified_by :batch_id, :name
      end
    end

    it "identified_by joins several paths, and offers no single HEAD for a composite", :aggregate_failures do
      identified = composite_identity_aggregate

      expect(identified.identity_paths).to eq(["batch_id", "name.value"])
      expect(identified.identity_heads).to eq([:batch_id, :name])
      expect(identified.identified_by).to be_nil
    end

    # Nothing is minted, so nothing defaults either — an aggregate with no
    # identity can't be created. Uses the raw builder, not
    # `build_aggregate`, which hands fixtures a baseline identity.
    it "identified_by has no default : an aggregate that declares none has none", :aggregate_failures do
      undeclared = Hecks::Bluebook::DSL::AggregateBuilder.build("Undeclared") { nil }

      expect(undeclared.identity_paths).to eq([])
      expect(undeclared.identified_by).to be_nil
    end

    describe "identified_by :field — deriving the path from a single-field value object" do
      def community_aggregate
        build_aggregate("Community") do
          identified_by :id
          value_object("CommunityId") { attribute :value, String }
          attribute :id, CommunityId
        end
      end

      it "derives the same path { field.value } would have written by hand", :aggregate_failures do
        identified = community_aggregate

        expect(identified.identity_paths).to eq(["id.value"])
        expect(identified.identified_by).to eq(:id)
      end

      def two_field_identity
        proc do
          identified_by :ref
          value_object("ThingRef") do
            attribute :value, String
            attribute :pad, Integer
          end
          attribute :ref, ThingRef
        end
      end

      it "refuses a value object with more than one field, naming every candidate" do
        message = /identified_by :ref names ThingRef, which has 2 fields \(value, pad\)/

        expect_refusal(:aggregate, "Thing", message, &two_field_identity)
      end

      it "refuses a field the aggregate never declares" do
        expect do
          build_aggregate("Thing") { identified_by :nonexistent }
        end.to raise_error(Malformed, /identified_by :nonexistent names no attribute Thing declares/)
      end

      # ADR 0025 — an identity head may be a single-field value object, a
      # bare scalar, or a reference; a reference is already a scalar id
      # (`reference_to` mints a bare attribute), so it resolves unchanged.
      def team_aggregate
        proc do
          aggregate "Team" do
            identified_by :name
            value_object("Name") { attribute :value, String }
            attribute :name, Name
          end
        end
      end

      def owner_identified_board
        proc do
          aggregate "Board" do
            identified_by :owner
            reference_to Team, as: :owner
          end
        end
      end

      it "admits a reference — already a scalar, nothing to derive", :aggregate_failures do
        bluebook = build_bluebook("Refs", &composed(team_aggregate, owner_identified_board))
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

      def game_entity
        proc do
          entity "Game" do
            identified_by :game_id
            attribute :game_id, GameId
          end
        end
      end

      def bracket_bluebook
        game = game_entity
        build_bluebook("Games") do
          aggregate "Bracket" do
            identified_by :bracket_id
            attribute :bracket_id, BracketId
            value_object("BracketId") { attribute :value, String }
            value_object("GameId")    { attribute :value, String }
            instance_eval(&game)
          end
        end
      end

      it "works the same way on an entity, deriving from the OWNING AGGREGATE's own value object", :aggregate_failures do
        game = bracket_bluebook.aggregate("Bracket").entities.first

        expect(game.identity_paths).to eq(["game_id.value"])
        expect(game.identified_by).to eq(:game_id)
      end
    end

    it "refuses as: on the bare-field-name form — there is no field left it could rename" do
      expect_refusal(:aggregate, "Thing", /Thing\.identified_by takes no as: — name the declared field itself/) do
        value_object("Name") { attribute :value, String }
        attribute :name, Name
        identified_by :name, as: :other
      end
    end

    def pizza_name_order
      build_aggregate("Order") do
        identified_by PizzaName
        value_object("PizzaName") { attribute :value, String }
      end
    end

    it "uses a value-object type as the live identity concept and mints its field", :aggregate_failures do
      identified = pizza_name_order

      expect(identified.identity_paths).to eq(["pizza_name.value"])
      expect(identified.attributes.map { |field| [field.name, field.type] }).to include([:pizza_name, "PizzaName"])
    end

    # Frozen era text using the value-object form passes through the
    # explicit shadow boundary directly at the DSL layer — the same
    # mechanism `EraGuard.shadow_parse` wraps its eval in.
    describe "identified_by ValueObject while shadow-parsing" do
      def legacy(&)
        Hecks::Bluebook::MetaValidator.while_shadow_parsing(&)
      end

      def pizza_name_order_as_name
        build_aggregate("Order") do
          identified_by PizzaName, as: :name
          value_object("PizzaName") { attribute :value, String }
        end
      end

      def thing_ref_order
        build_aggregate("Thing") do
          identified_by ThingRef
          value_object("ThingRef") do
            attribute :value, String
            attribute :pad, Integer
          end
        end
      end

      def winner_entity
        proc do
          entity "Game" do
            identified_by WinnerRef, as: :winner
          end
        end
      end

      def winner_bracket
        game = winner_entity
        build_bluebook("Games") do
          aggregate "Bracket" do
            identified_by :bracket_id
            attribute :bracket_id, BracketId
            value_object("BracketId") { attribute :value, String }
            value_object("WinnerRef") { attribute :value, String }
            instance_eval(&game)
          end
        end
      end

      it "mints the attribute AND derives its path, no separate attribute call needed", :aggregate_failures do
        found = legacy { pizza_name_order }

        expect(found.identified_by).to eq(:pizza_name)
        expect(found.identity_paths).to eq(["pizza_name.value"])
        expect(found.attributes.map { |a| [a.name, a.type] }).to eq([[:pizza_name, "PizzaName"]])
      end

      it "as: overrides the minted attribute's own name", :aggregate_failures do
        found = legacy { pizza_name_order_as_name }

        expect(found.identified_by).to eq(:name)
        expect(found.identity_paths).to eq(["name.value"])
        expect(found.attributes.map(&:name)).to eq([:name])
      end

      it "expands a multi-field value object in declaration order" do
        found = legacy { thing_ref_order }

        expect(found.identity_paths).to eq(["thing_ref.value", "thing_ref.pad"])
      end

      it "refuses a type naming no declared value object" do
        expect do
          legacy { build_aggregate("Thing") { identified_by Nonexistent } }
        end.to raise_error(Malformed, /identified_by names Nonexistent, which is not a declared value object/)
      end

      it "works the same way on an entity, minting from the OWNING AGGREGATE's own value object", :aggregate_failures do
        game = legacy { winner_bracket }.aggregate("Bracket").entities.first

        expect(game.identified_by).to eq(:winner)
        expect(game.identity_paths).to eq(["winner.value"])
        expect(game.attributes.map { |a| [a.name, a.type] }).to eq([[:winner, "WinnerRef"]])
      end
    end

    def lifecycle_machine(default, &transitions)
      build_aggregate("Machine") { lifecycle(:status, default: default, &transitions) }.lifecycle
    end

    def expect_lifecycle_refusal(message, &transitions)
      expect_refusal(:aggregate, "Machine", message) { lifecycle(:status, default: "open", &transitions) }
    end

    it "lifecycle records a state machine on a field", :aggregate_failures do
      machine = lifecycle_machine("pending") { transition "Purchase" => "sold" }

      expect([machine.field, machine.default]).to eq([:status, "pending"])
      expect(machine.target_for("Purchase")).to eq("sold")
    end

    # The lifecycle field moves only by transition; the state machine is
    # checked whole at build — no `sets` on the field, no `from:` naming
    # an undeclared state, no two transitions for one command.
    it "refuses sets on the lifecycle field — it moves only by transition" do
      expect_refusal(:aggregate, "Bypassed", /Force sets status, Thing's lifecycle field/) do
        lifecycle(:status, default: "open") { transition "Close" => "closed", from: "open" }
        command("Force") { sets :status, to: "closed" }
      end
    end

    it "refuses two transitions for one command from the same state — which fires would be declaration order" do
      expect_lifecycle_refusal(/declares two transitions for "Close" from the same state/) do
        transition "Close" => "closed", from: "open"
        transition "Close" => "shut",   from: "open"
      end
    end

    it "keeps two transitions for one command from disjoint states — the current state picks" do
      machine = lifecycle_machine("open") do
        transition "Close" => "closed",   from: "open"
        transition "Close" => "archived", from: "closed"
      end

      expect(machine.target_for("Close", "closed")).to eq("archived")
    end

    def invarianted_aggregate
      build_aggregate("Invarianted") do
        value_object("Balance") { attribute :cents, Integer }
        attribute :balance, Balance

        invariant("the balance never goes negative") { balance.cents >= 0 }
      end
    end

    it "invariant declares an aggregate-level rule, checked after every command", :aggregate_failures do
      built = invarianted_aggregate

      expect(built.invariants.map(&:description)).to eq(["the balance never goes negative"])
      expect(built.invariants.first.canonical).to include("cents")
    end

    def preconditioned_aggregate
      build_aggregate("Preconditioned") do
        value_object("Status") { attribute :value, String }
        attribute :status, Status

        given("the record is open") { status.value == "open" }

        command("Close") { given("the record is open") }
      end
    end

    it "given at the aggregate level declares a precondition once, and a command names it back", :aggregate_failures do
      built = preconditioned_aggregate

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

    def lifecycled_customer
      proc do
        aggregate("Customer") do
          identified_by :id
          lifecycle :status, default: "active" do
            transition "Suspend" => "suspended", from: "active"
          end
        end
      end
    end

    def projecting_account_from(path, name = :nope)
      proc do
        aggregate("Account") do
          identified_by :id
          reference_to Customer

          projects name, from: path
        end
      end
    end

    it "projects declares a field read locally through a reference", :aggregate_failures do
      parts = composed(lifecycled_customer, projecting_account_from(:"customer.status", :customer_status))
      field = build_bluebook("Projecting", &parts).aggregate("Account").projected_fields.first

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
      expect_refusal(:aggregate, "NotAReference", /never declares.*as a reference_to/) do
        value_object("Status") { attribute :value, String }
        attribute :status, Status

        projects :nope, from: :"status.value"
      end
    end

    it "projects refuses a remote field the target aggregate never declares" do
      customer = proc { aggregate("Customer") { identified_by :id } }

      expect_refusal(:bluebook, "UnknownRemoteField", /never declares/,
                     &composed(customer, projecting_account_from(:"customer.nonexistent")))
    end

    def region_and_customer
      proc do
        aggregate("Region") { identified_by :id }

        aggregate("Customer") do
          identified_by :id
          reference_to Region
        end
      end
    end

    it "projects refuses landing on a reference or value object, not a scalar" do
      expect_refusal(:bluebook, "NonScalarProjection", /not a scalar/,
                     &composed(region_and_customer, projecting_account_from(:"customer.region")))
    end

    def customer_with_value_object(*fields)
      proc do
        aggregate("Customer") do
          identified_by :id
          value_object("Since") { fields.each { |name| attribute name, Integer } }
          attribute :since, Since
        end
      end
    end

    it "projects accepts a remote field typed by a single-field value object" do
      parts = composed(customer_with_value_object(:value), projecting_account_from(:"customer.since"))

      expect { build_bluebook("SingleFieldProjection", &parts) }.not_to raise_error
    end

    it "projects refuses a remote field typed by a multi-field value object" do
      expect_refusal(:bluebook, "MultiFieldProjection", /not a scalar/,
                     &composed(customer_with_value_object(:year, :month), projecting_account_from(:"customer.since")))
    end

    def customer_with_tags
      proc do
        aggregate("Customer") do
          identified_by :id
          value_object("Tag") { attribute :value, String }
          attribute :tags, list_of(Tag)
        end
      end
    end

    it "projects refuses a remote list" do
      expect_refusal(:bluebook, "ListProjection", /not a scalar/,
                     &composed(customer_with_tags, projecting_account_from(:"customer.tags")))
    end

    def guarded_launch_command
      build_bluebook("Guarding") do
        aggregate("Launch") do
          identified_by :id

          lifecycle :status, default: "open" do
            transition "Shut" => "shut", from: "open"
          end

          command("Peek", from: "open")
        end
      end.aggregate("Launch").command("Peek")
    end

    it "command's from: guards against the lifecycle field, without transitioning it", :aggregate_failures do
      command = guarded_launch_command

      expect(command.from).to eq("open")
      expect(command.mutations).to be_empty
    end

    it "command's from: refuses when the aggregate declares no lifecycle to check it against" do
      expect do
        build_aggregate("Lifecycleless") { command("Go", from: "open") }
      end.to raise_error(Malformed, /guards from: \["open"\], but Thing declares no lifecycle/)
    end

    it "lifecycle keeps a from: list as written", :aggregate_failures do
      machine = lifecycle_machine("draft") { transition "Archive" => "archived", from: ["sold", "draft"] }

      expect(machine.transitions.size).to eq(1)
      expect(machine.transitions.first.last.from).to eq(["sold", "draft"])
    end

    it "lifecycle flattens a from: list only when dumped" do
      machine = lifecycle_machine("draft") { transition "Archive" => "archived", from: ["sold", "draft"] }

      expect(machine.to_h[:transitions]).to eq([{ command: "Archive", to_state: "archived", from_state: "sold" },
                                                { command: "Archive", to_state: "archived", from_state: "draft" }])
    end

    def advancing_machine
      lifecycle_machine("a") do
        transition "Advance" => "b", from: "a"
        transition "Advance" => "c", from: "b"
      end
    end

    it "lifecycle picks the transition whose from: admits the current state", :aggregate_failures do
      machine = advancing_machine

      expect(machine.target_for("Advance", "a")).to eq("b")
      expect(machine.target_for("Advance", "b")).to eq("c")
      expect(machine.states).to eq(["a", "b", "c"])
    end

    it "lifecycle refuses to guess a target when no declared from: admits the current state" do
      # "z" admits neither declared transition — silently falling back to
      # the first one would be a wrong answer, rather than the loud
      # refusal every real dispatch path gets from `admissible_transition`.
      expect { advancing_machine.target_for("Advance", "z") }
        .to raise_error(Hecks::Runtime::WiringError, /no transition for "Advance" admits state "z"/)
    end

    def order_line_entity
      build_aggregate("Ordered") do
        entity "OrderLine" do
          identified_by :sku
          attribute :sku,      Sku
          attribute :quantity, Quantity
        end
        value_object("Sku") { attribute :value, String }
        value_object("Quantity") { attribute :value, Integer }
      end.entities.first
    end

    it "entity declares an identity-bearing member inside the boundary", :aggregate_failures do
      line = order_line_entity

      expect([line.hecks_name, line.identified_by]).to eq(["OrderLine", :sku])
      expect(line.attribute(:quantity).type).to eq("Quantity")
    end

    def available_clauses
      proc do
        where(status: "available")
        order_by :name, :desc
        limit 10
        offset 5
        nulls :last
        authorize :customer_access, tenant: :account_id
        inspect_query :sql
      end
    end

    def available_query
      clauses = available_clauses
      proc { query("Available", &clauses) }
    end

    def readable_query
      available = available_query
      build_aggregate("Readable") do
        # The fields the query below asks about. A query must name a field the
        # aggregate declares (AggregateBuilder#seal_query_targets), so the
        # fixture declares them instead of asking into a void.
        value_object("Name") { attribute :value, String }
        attribute :name, Name
        lifecycle(:status, default: "available") { transition "Retire" => "retired", from: "available" }
        instance_eval(&available)
      end.queries.first
    end

    it "query records its name, filters and ordering as DATA, never a proc", :aggregate_failures do
      found = readable_query

      expect(found.name).to eq("Available")
      expect(found.wheres.map(&:to_h)).to eq([{ field: "status", op: "eq", value: '"available"' }])
      expect(found.order_by.to_h).to eq({ field: "name", direction: "desc" })
    end

    it "query records a cap and a window as DATA, never a proc", :aggregate_failures do
      found = readable_query

      expect(found.limit.to_h).to eq({ value: "10" })
      expect(found.offset.to_h).to eq({ value: "5" })
      expect(found.null_semantics.to_h).to eq({ mode: "last" })
    end

    it "query records its authorization and inspection as DATA, never a proc", :aggregate_failures do
      found = readable_query

      expect(found.authorization.to_h).to eq({ policy: "customer_access", tenant: "account_id" })
      expect(found.inspection.to_h).to eq({ mode: "sql" })
    end

    def name_declaration
      proc do
        value_object("Name") { attribute :value, String }
        attribute :name, Name
      end
    end

    def cursored_available_query
      proc do
        query "Available" do
          where(name: "x")
          cursor :after
        end
      end
    end

    it "query refuses cursor at build — no interpreter implements cursor pagination" do
      message = /declares cursor, but no interpreter implements cursor pagination/

      expect_refusal(:aggregate, "Cursored", message, &composed(name_declaration, cursored_available_query))
    end

    def build_priced(name, &queries)
      build_aggregate(name) do
        value_object("Price") { attribute :cents, Integer }
        attribute :price, Price
        instance_eval(&queries)
      end
    end

    it "query reads a comparator from the hash form" do
      found = build_priced("Compared") { query("Cheap") { where(price: { lt: 500 }) } }.queries.first

      expect(found.wheres.first.to_h).to eq({ field: "price", op: "lt", value: "500" })
    end

    it "query refuses a comparator it does not know, rather than reading it as a literal" do
      expect_refusal(:aggregate, "Mistyped", /unknown comparator/, ArgumentError) do
        query("Broken") { where(price: { greater_than: 5 }) }
      end
    end

    describe "a query's own block parameter, derived from the owner's already-declared attribute" do
      # The block parameter's name is read by reflection (`block.parameters`) to derive the
      # attribute, so each query below keeps a parameter its body never reads.
      def decision_query
        proc do
          query "ForDecision" do |decision| # rubocop:disable Lint/UnusedBlockArgument -- name read by reflection
            where decision: :decision
          end
        end
      end

      def redundant_decision_query
        proc do
          query "ForDecision" do |decision| # rubocop:disable Lint/UnusedBlockArgument -- name read by reflection
            attribute :decision, DecisionRef
            where decision: :decision
          end
        end
      end

      def decision_submission(&queries)
        build_aggregate("Submission") do
          value_object("DecisionRef") { attribute :value, String }
          attribute :decision, DecisionRef
          instance_eval(&queries)
        end
      end

      def noted_submission
        build_aggregate("Submission") do
          value_object("Note") { attribute :value, String }
          attribute :note, Note, optional: true

          query "ByNote" do |note| # rubocop:disable Lint/UnusedBlockArgument -- name read by reflection
            where note: :note
          end
        end
      end

      def unmatched_parameter_submission
        build_aggregate("Submission") do
          value_object("Name") { attribute :value, String }
          attribute :name, Name

          query "Broken" do |nonexistent| # rubocop:disable Lint/UnusedBlockArgument -- name read by reflection
            where name: "open"
          end
        end
      end

      def bracket_value_objects
        proc do
          value_object("BracketId") { attribute :value, String }
          value_object("GameId")    { attribute :value, String }
          value_object("WinnerRef") { attribute :value, String }
        end
      end

      def winner_game_entity
        proc do
          entity "Game" do
            identified_by :game_id
            attribute :game_id, GameId
            attribute :winner, WinnerRef

            query "WinsByOption" do |winner| # rubocop:disable Lint/UnusedBlockArgument -- name read by reflection
              where winner: :winner
            end
          end
        end
      end

      def winners_bluebook
        parts = [bracket_value_objects, winner_game_entity]
        build_bluebook("Games") do
          aggregate "Bracket" do
            identified_by :bracket_id
            attribute :bracket_id, BracketId
            parts.each { |part| instance_eval(&part) }
          end
        end
      end

      it "derives the block parameter's type from the aggregate's own matching attribute, no attribute call needed" do
        found = decision_submission(&decision_query).queries.first

        expect(found.attributes.map { |a| [a.name, a.type] }).to eq([[:decision, "DecisionRef"]])
      end

      it "still works when the block also declares the attribute explicitly (no duplicate)" do
        found = decision_submission(&redundant_decision_query).queries.first

        expect(found.attributes.map(&:name)).to eq([:decision])
      end

      it "carries optional: true through from the owner's own attribute" do
        found = noted_submission.queries.first

        expect(found.attributes.first.optional?).to be(true)
      end

      it "leaves a block parameter alone when nothing on the owner matches it — no attribute silently invented" do
        found = unmatched_parameter_submission.queries.first

        expect(found.attributes).to be_empty
      end

      it "derives from the OWNING ENTITY's own attribute too, not just an aggregate's" do
        found = winners_bluebook.aggregate("Bracket").entities.first.queries.first

        expect(found.attributes.map { |a| [a.name, a.type] }).to eq([[:winner, "WinnerRef"]])
      end
    end

    # Without this seal, every case here would build cleanly and answer
    # wrongly: an undeclared-field where matches nothing, an ordered
    # comparator differs per adapter, a bad :symbol resolves to nil.
    describe "a query the aggregate cannot answer" do
      def build_pizza_price(name, &queries)
        build_aggregate(name) do
          value_object("Price") { attribute :cents, Integer }
          value_object("Pizza") { attribute :price, Price }
          attribute :pizza, Pizza
          instance_eval(&queries)
        end
      end

      def build_pizza_label(name, &queries)
        build_aggregate(name) do
          value_object("Label") { attribute :text, String }
          value_object("Pizza") { attribute :label, Label }
          attribute :pizza, Pizza
          instance_eval(&queries)
        end
      end

      def cheap_dotted_query
        proc do
          query("Cheap") do
            where("pizza.price.cents": { lt: 500 })
            order_by :"pizza.price.cents", :desc
          end
        end
      end

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
        expect_refusal(:aggregate, "Texting", /compares label with gt.*holds no number.*adapters answer differently/m) do
          value_object("Label") { attribute :value, String }
          attribute :label, Label
          query("Sorted") { where(label: { gt: "m" }) }
        end
      end

      it "refuses an ordered comparator over the lifecycle field" do
        expect_refusal(:aggregate, "Cycling", /compares status with lt.*lifecycle field, which holds text/m) do
          lifecycle(:status, default: "open") { transition "Close" => "closed", from: "open" }
          query("Sorted") { where(status: { lt: "open" }) }
        end
      end

      it "infers a symbolic query argument from the compared field" do
        aggregate = build_priced("Arguing") { query("Cheap") { where(price: { lt: :ceiling }) } }
        ceiling = aggregate.query("Cheap").attribute(:ceiling)

        expect([ceiling.name, ceiling.type.to_s]).to eq([:ceiling, "Price"])
      end

      it "still requires an explicit argument when no compared field supplies its type" do
        message = /resolves :page_size from its arguments, but declares no page_size attribute/

        expect_refusal(:aggregate, "Paging", message) do
          attribute :name, String
          query("Page") { limit :page_size }
        end
      end

      it "admits a dotted path that lands on a scalar member, at any depth" do
        aggregate = build_pizza_price("Nesting", &cheap_dotted_query)

        expect(aggregate.queries.first.wheres.first.field.to_s).to eq("pizza.price.cents")
      end

      it "refuses a dotted path that lands on a value object rather than a scalar" do
        expect { build_pizza_price("Landing") { query("Cheap") { where("pizza.price": { lt: 500 }) } } }
          .to raise_error(Malformed, /asks about pizza\.price, which lands on a value object, not a scalar/)
      end

      it "refuses an ordered comparator on a dotted path to a non-numeric scalar" do
        expect { build_pizza_label("Lettering") { query("Sorted") { where("pizza.label.text": { gt: "m" }) } } }
          .to raise_error(Malformed, /compares pizza\.label\.text with gt.*holds no number/m)
      end

      def everything_query
        proc do
          query "Everything" do
            attribute :floor, Money
            where(status: { in: "open,closed" }, balance: { lt: :floor },
                  tags: { contains: "hot" }, name: { ne: "x" })
            order_by :name
            limit 10
          end
        end
      end

      def sound_types
        proc do
          value_object("Money")  { attribute :cents, Integer }
          value_object("Name")   { attribute :value, String }
          value_object("Tag")    { attribute :name, String }
        end
      end

      def sound_aggregate
        types = sound_types
        everything = everything_query
        build_aggregate("Sound") do
          instance_eval(&types)
          attribute :balance, Money
          attribute :name,    Name
          attribute :tags,    list_of(Tag)
          lifecycle(:status, default: "open") { transition "Close" => "closed", from: "open" }
          instance_eval(&everything)
        end
      end

      it "admits the shapes both adapters answer identically" do
        expect(sound_aggregate.queries.first.wheres.size).to eq(4)
      end
    end

    describe "a slash path that hops through a reference" do
      def hop_client_aggregate(client)
        proc do
          aggregate "Client" do
            identified_by :name
            attribute :name, ClientName
            value_object("ClientName") { attribute :value, String }
            lifecycle(:status, default: "active") { transition "Churn" => "churned", from: "active" }
            instance_eval(&client) if client
          end
        end
      end

      def hop_proposal_aggregate(proposal_query)
        proc do
          aggregate "Proposal" do
            identified_by :number
            reference_to Client
            attribute :number, ProposalNumber
            value_object("ProposalNumber") { attribute :value, String }
            instance_eval(&proposal_query)
          end
        end
      end

      def build_hop_bluebook(name = "Hopping", client: nil, &proposal_query)
        build_bluebook(name, &composed(hop_client_aggregate(client), hop_proposal_aggregate(proposal_query)))
      end

      def expect_hop_refusal(message, client: nil, &proposal_query)
        expect { build_hop_bluebook(client: client, &proposal_query) }.to raise_error(Malformed, message)
      end

      def balance_client
        proc do
          value_object("Balance") { attribute :cents, Integer }
          attribute :balance, Balance
        end
      end

      def box_client
        proc do
          value_object("Price") { attribute :cents, Integer }
          value_object("Box")   { attribute :price, Price }
          attribute :box, Box
        end
      end

      def lifecycle_gt_message
        %r{
          compares\ client/status\ with\ gt\ after\ hopping\ to\ Client
          .*
          is\ the\ lifecycle\ field,\ which\ holds\ text
        }mx
      end

      def hop_product_aggregate
        proc do
          aggregate "Product" do
            identified_by :sku
            attribute :sku, ProductSku
            value_object("ProductSku") { attribute :value, String }
          end
        end
      end

      def product_card_entity
        proc do
          entity "Card" do
            identified_by :sequence
            attribute :sequence, Integer
            reference_to Product

            query("ForProduct") { where("product/sku": "widget") }
          end
        end
      end

      def nonexistent_card_entity
        proc do
          entity "Card" do
            identified_by :sequence
            attribute :sequence, Integer
            reference_to Nonexistent

            query("ForNonexistent") { where("nonexistent/sku": "widget") }
          end
        end
      end

      def board_with(card)
        proc do
          aggregate "Board" do
            identified_by :tag
            attribute :tag, BoardTag
            value_object("BoardTag") { attribute :value, String }
            instance_eval(&card)
          end
        end
      end

      def engagement_aggregate
        proc do
          aggregate "Engagement" do
            identified_by :reference
            reference_to Client
            attribute :reference, EngagementRef
            value_object("EngagementRef") { attribute :value, String }
          end
        end
      end

      def engaged_proposal_aggregate
        proc do
          aggregate "Proposal" do
            identified_by :number
            reference_to Engagement
            attribute :number, ProposalNumber
            value_object("ProposalNumber") { attribute :value, String }
            query("AwaitingReply") { where("engagement/client/status": "active") }
          end
        end
      end

      def self_referential_node
        proc do
          aggregate "Node" do
            identified_by :label
            reference_to Node, as: :parent
            attribute :label, NodeLabel
            value_object("NodeLabel") { attribute :value, String }
            query("GrandparentLabel") { where("parent/parent/label": "root") }
          end
        end
      end

      def deep_node
        proc do
          aggregate "Node" do
            identified_by :label
            reference_to Node
            attribute :label, NodeLabel
            value_object("NodeLabel") { attribute :value, String }
            nine = ((["node"] * 9) + ["label"]).join("/")
            query("TooFar") { where(nine.to_sym => "root") }
          end
        end
      end

      def studio_aggregate
        proc do
          aggregate "Studio" do
            identified_by :name
            attribute :name, StudioName
            value_object("StudioName") { attribute :value, String }
          end
        end
      end

      def studio_piece_aggregate(piece_query)
        proc do
          aggregate "Piece" do
            identified_by :tag
            reference_to Studio, as: :studio
            attribute :tag, PieceTag
            value_object("PieceTag") { attribute :value, String }
            instance_eval(&piece_query)
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
          build_hop_bluebook(client: balance_client) { query("HighValue") { where("client/balance.cents": { gt: 500 }) } }
        end.not_to raise_error
      end

      it "refuses ORDER BY through a hop outright — an ask is ordered by its own rows, not a candidate set" do
        message = %r{orders by client/status, which hops through a reference}

        expect_hop_refusal(message) { query("BadOrder") { order_by :"client/status" } }
      end

      it "refuses a hop into an aggregate this chapter never declares" do
        message = %r{asks about client/status, which hops to Client, which this chapter never declares}
        bad_query = proc { query("Bad") { where("client/status": "active") } }

        expect_refusal(:bluebook, "Dangling", message, &hop_proposal_aggregate(bad_query))
      end

      it "refuses a hop whose tail names nothing the target declares" do
        message = /hops to Client and then asks about nonexistent, which Client never declares/

        expect_hop_refusal(message) { query("Bad") { where("client/nonexistent": "x") } }
      end

      # An entity's own `reference_to` was uncheckable at declaration
      # and unresolved at runtime; a where over a piece's own hop built
      # cleanly and matched nothing, forever, on every adapter.
      it "refuses a hop where-clause on an entity's own query" do
        message = %r{Board::Card\.ForProduct asks about product/sku, which hops through Card's own reference}
        parts = composed(board_with(product_card_entity), hop_product_aggregate)

        expect_refusal(:bluebook, "PieceHop", message, &parts)
      end

      # The blanket refusal above already catches this unconditionally;
      # pinned separately so a future loosening of that refusal (e.g.
      # teaching entity queries to follow a hop) can't reopen this gap.
      it "refuses a hop where-clause on an entity's own query through an aggregate the chapter never declares" do
        message = %r{Board::Card\.ForNonexistent asks about nonexistent/sku, which hops through Card's own reference}

        expect_refusal(:bluebook, "PieceHopUndeclared", message, &board_with(nonexistent_card_entity))
      end

      it "refuses a hop whose tail lands on a value object rather than a scalar" do
        # A bare tail landing on a value object ("client.balance") is
        # fine; a second dotted level landing on a nested value object
        # (Box -> Price) is what refuses.
        message = /hops to Client and then asks about box\.price, which lands on a value object, not a scalar/

        expect_hop_refusal(message, client: box_client) { query("Bad") { where("client/box.price": { gt: 500 }) } }
      end

      it "refuses an ordered comparator on a hop's tail when it holds no number" do
        expect_hop_refusal(lifecycle_gt_message) { query("Bad") { where("client/status": { gt: "active" }) } }
      end

      it "refuses an ordered comparator on a hop's tail that's a real attribute holding no number" do
        message = %r{compares client/note with gt after hopping to Client.*holds no number}m

        expect_hop_refusal(message, client: proc { attribute :note, String }) do
          query("Bad") { where("client/note": { gt: "z" }) }
        end
      end

      it "a multi-hop chain reads left to right, outward to inward" do
        parts = composed(hop_client_aggregate(nil), engagement_aggregate, engaged_proposal_aggregate)
        bluebook = build_bluebook("MultiHop", &parts)

        expect(bluebook.aggregate("Proposal").queries.first.wheres.first.field.to_s)
          .to eq("engagement/client/status")
      end

      it "admits a self-referential hop chain — revisiting the same aggregate TYPE is not a cycle" do
        expect { build_bluebook("SelfRef", &self_referential_node) }.not_to raise_error
      end

      it "refuses a hop chain deep enough to be a mistake, not because anything could loop forever" do
        message = /whose hop chain reaches 8 references deep/

        expect_refusal(:bluebook, "TooDeep", message, &deep_node)
      end

      # `/` crosses into another record, `.` walks fields inside this
      # one (ADR 0025) — the operator alone decides, regardless of what
      # the reference is named (`as: :studio`).
      it "a dot onto a reference attribute never hops — it dead-ends the same way any dotted path onto a " \
         "non-value-object does" do
        bad = proc { query("Bad") { where("studio.name": "x") } }

        expect_refusal(:bluebook, "NoDotHop", /asks about studio\.name, which Piece never declares/,
                       &composed(studio_aggregate, studio_piece_aggregate(bad)))
      end

      it "a slash onto the same reference IS the hop" do
        good = proc { query("Good") { where("studio/name.value": "x") } }
        bluebook = build_bluebook("SlashHop", &composed(studio_aggregate, studio_piece_aggregate(good)))

        expect(bluebook.aggregate("Piece").queries.first.wheres.first.field.to_s).to eq("studio/name.value")
      end
    end

    def customer_then_thing_command
      build_bluebook("Open") do
        aggregate("Customer") do
          identified_by :id
          description "A customer"
        end
        aggregate("Thing") do
          identified_by :id
          command("Do") { reference_to "Customer" }
        end
      end.aggregate("Thing").command("Do")
    end

    it "reference_to another root is an attribute, and leaves the command creating", :aggregate_failures do
      command = customer_then_thing_command

      expect(command.creates?).to be true
      # Both assertions must reflect the real `Reference`, not a same-
      # named string; `reference_to` mints the bare name `customer`,
      # never `customer_id` (ADR 0025).
      expect(command.attribute(:customer).type.target_name).to eq("Customer")
      expect(command.attribute(:customer).to_h[:type]).to eq("Reference<Customer>")
    end

    it "reference_to its OWN root makes the command act on an existing one", :aggregate_failures do
      command = build_command("Debit") { reference_to "Thing" }

      expect(command.creates?).to be false
      expect(command.references).to eq("Thing")
    end

    def reactive_policy
      build_aggregate("Reactive") do
        policy "ChargeOnPlacement" do
          on      "Order.Placed"
          trigger Payment::Charge
        end
      end.policies.first
    end

    it "policy binds an event to the command it triggers", :aggregate_failures do
      reaction = reactive_policy

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

    def pizza_referring_thing
      build_bluebook("Referring") do
        aggregate("Pizza") do
          identified_by :id
          description "A pizza"
        end
        aggregate("Thing") do
          identified_by :id
          reference_to Pizza
        end
      end.aggregate("Thing")
    end

    it "reference_to points at another root by its identity, minting the bare name — no _id", :aggregate_failures do
      aggregate = pizza_referring_thing

      expect(aggregate.attribute(:pizza).type.target_name).to eq("Pizza")
      expect(aggregate.attribute(:pizza).to_h[:type]).to eq("Reference<Pizza>")
    end

    def warehouse_aggregate
      proc do
        aggregate("Warehouse") do
          identified_by :id
          description "A warehouse"
        end
      end
    end

    def shipment_aggregate
      proc do
        aggregate("Shipment") do
          identified_by :id
          reference_to Warehouse, as: :origin
          reference_to Warehouse, as: :destination
        end
      end
    end

    it "reference_to still takes as: to override the default name, the way has_* used to", :aggregate_failures do
      bluebook = build_bluebook("Aliased", &composed(warehouse_aggregate, shipment_aggregate))
      aggregate = bluebook.aggregate("Shipment")

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
      expect(build_aggregate("Stored") { nil }.storage_name).to eq("thing")
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

    def size_invariant_value_object
      build_value_object("VoInv") do
        attribute :size, Integer
        invariant "size must be positive" do
          size.positive?
        end
      end
    end

    it "invariant records the rule AND its extracted expression", :aggregate_failures do
      invariant = size_invariant_value_object.invariants.first

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
      expect(build_command("CmdCreate") { nil }.creates?).to be(true)
    end

    def given_command
      build_command("CmdGiven") do
        given("must be open") { status == "open" }
      end
    end

    it "given records the guard AND its extracted expression", :aggregate_failures do
      given = given_command.givens.first

      expect(given.description).to eq("must be open")
      expect(given.canonical).to eq('status == "open"')
    end

    def remap_command
      build_command("CmdSetArg") do
        attribute :new_status, Tag
        sets :status, to: :new_status
      end
    end

    it "sets to: a symbol reads a command argument — a genuine remap, a different field", :aggregate_failures do
      mutation = remap_command.mutations.first

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
    it "sets to: false is a real mutation, not an absent to:", :aggregate_failures do
      mutation = build_command("CmdSetToFalse") { sets :status, to: false }.mutations.first

      expect(mutation.op).to eq(:set)
      expect(mutation.to_h[:source]).to eq(kind: "literal", value: false)
    end

    it "sets :field, true reads as to: true — a bare positional boolean shorthand", :aggregate_failures do
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
    it "delegates_to records a :delegate mutation naming the target and the field map", :aggregate_failures do
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
      expect_refusal(:command, "CmdDelegateNotPure", /pure passthrough/) do
        delegates_to "Piece.Move", with: { id: :id }
        emits "SomethingElseToo"
      end
    end

    # `corrects` declares what past event a command amends, the append-
    # only answer to retroactive correction, recorded as a `:corrects`-op
    # Mutation. These specs cover the DSL surface only.
    # `seal_correction_targets` refuses a `corrects` naming an event nothing in the aggregate
    # emits, so the fixture needs a sibling command that really emits it.
    def correcting_aggregate
      build_aggregate("CmdCorrects") do
        command("Happen") { emits "SomethingHappened" }
        command("Fix") { corrects "SomethingHappened", as: :original, reason: "it was wrong" }
      end
    end

    it "corrects records a :corrects mutation naming the event and the reason", :aggregate_failures do
      mutation = correcting_aggregate.commands.find { |c| c.hecks_name == "Fix" }.mutations.first

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
    it "sets append: state(:field) copies the owner's own field into the element", :aggregate_failures do
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

    it "sets append: pushes a built value object onto a list", :aggregate_failures do
      mutation = build_command("CmdAppend") { sets :parts, append: { size: :size } }.mutations.first

      expect([mutation.target, mutation.op]).to eq([:parts, :append])
      expect(mutation.to_h[:fields]).to eq(size: ":size")
    end

    def incrementing_command
      build_command("CmdInc") do
        attribute :amount, Size
        sets :balance, increment: :amount
      end
    end

    it "sets increment: reads a command argument to add", :aggregate_failures do
      mutation = incrementing_command.mutations.first

      expect([mutation.target, mutation.op]).to eq([:balance, :increment])
      expect(mutation.to_h[:source]).to eq(kind: "argument", name: "amount")
    end

    it "sets decrement: takes a literal amount away", :aggregate_failures do
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
    it "sets :field, to: \"field\" — a literal spelling the field's name — imports nothing", :aggregate_failures do
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

    it "signal says whether the domain gets a value back or announces an event", :aggregate_failures do
      expect(build_port { signal :effect }.signal).to eq(:effect)
      expect(build_port { verb "x" }.signal).to eq(:reply)
    end

    it "reply? and effect? read the signal", :aggregate_failures do
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

    it "secret names one too, kept apart from plain fields", :aggregate_failures do
      adapter = build_adapter { secret :token }

      expect(adapter.secrets).to eq([:token])
      expect(adapter.fields).to eq([])
    end

    def office_token_adapter
      build_adapter do
        field  :office
        secret :token
      end
    end

    it "declares? answers for fields and secrets alike", :aggregate_failures do
      adapter = office_token_adapter

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
      registry = thing_registry("DomPort") { DomPort::Thing.port("Gateway", &block) }
      registry.bluebook("DomPort").aggregate("Thing").port("Gateway")
    end

    def receive_operation
      proc do
        operation("Receive") do
          attribute :thing_id, Hecks::Bluebook::Reference.new("Thing")
          emits "Received"
        end
      end
    end

    def build_both_ports(name, &declaration)
      [Hecks::Bluebook::DSL::DomainPortBuilder.build(name, &declaration),
       Hecks::Bluebook::DSL::PortBuilder.build(name, &declaration)]
    end

    def projection_declaration
      proc do
        verb "projected_by"
        signal :effect
      end
    end

    def extraction_declaration
      proc do
        verb "extracted_by"
        signal :reply
        answers :canonical
      end
    end

    it "operation adds a named operation" do
      port = build_domain_port(&receive_operation)

      expect(port.operation("Receive").hecks_name).to eq("Receive")
    end

    # The driven half, reached through the same `port` call, registered
    # the same way `Hecks.port`'s top-level method registers one
    # (`registry.ports`, not the aggregate's own IR).
    it "verb builds a resource-style port, registered the same way Hecks.port is", :aggregate_failures do
      registry = thing_registry("DomPortVerb") { DomPortVerb::Thing.port("Checkout") { verb "opened_by" } }
      port = registry.ports["Checkout"]

      expect(port.verb).to eq("opened_by")
      expect(registry.bluebook("DomPortVerb").aggregate("Thing").port("Checkout")).to be_nil
    end

    # Proves `DomainPortBuilder`'s bare-verb fallback produces a `Port`
    # byte-identical to `PortBuilder`'s. `signal :effect` and `answers`
    # are real corpus uses, not hypothetical ones.
    it "signal builds the same Port PortBuilder itself would, non-default value included", :aggregate_failures do
      via_domain_port, via_port_builder = build_both_ports("projection", &projection_declaration)

      expect(via_domain_port).to be_a(Hecks::Bluebook::Port)
      expect(via_domain_port.to_h).to eq(via_port_builder.to_h)
      expect(via_domain_port.signal).to eq(:effect)
    end

    it "answers builds the same Port PortBuilder itself would", :aggregate_failures do
      via_domain_port, via_port_builder = build_both_ports("extraction", &extraction_declaration)

      expect(via_domain_port).to be_a(Hecks::Bluebook::Port)
      expect(via_domain_port.to_h).to eq(via_port_builder.to_h)
      expect(via_domain_port.answers).to eq([:canonical])
    end

    it "refuses a port declaring both a verb and operations" do
      both = composed(proc { verb "opened_by" }, receive_operation)

      expect { build_domain_port(&both) }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /declares both a verb and operations/)
    end

    it "answers_query binds a query to the port, and says nothing of the shape its answer takes", :aggregate_failures do
      port = build_domain_port { answers_query "Census" }

      expect(port.answer_for("Census")).to have_attributes(name: "Census")
      expect(port.to_h).to include(answered_queries: [{ name: "Census" }])
    end

    it "answers_query refuses the shape: it once took" do
      expect { build_domain_port { answers_query "Census", shape: :rows } }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /shape/)
    end

    it "answers_query refuses a query bound twice" do
      twice = proc do
        answers_query "Census"
        answers_query "Census"
      end

      expect { build_domain_port(&twice) }.to raise_error(Hecks::Bluebook::DSL::Malformed, /binds Census twice/)
    end

    it "refuses a port with no verb and no operations" do
      expect { build_domain_port { nil } }.to raise_error(Hecks::Bluebook::DSL::Malformed, /declares no verb and no operations/)
    end

    it "a bare port at a hecksagon's root belongs to the chapter, not one aggregate" do
      registry = thing_registry("RootPort") { port("Clock") { operation("Tick") { emits "Ticked" } } }
      port = registry.bluebook("RootPort").port("Clock")

      expect(port.operation("Tick").emits).to eq(["Ticked"])
    end

    it "a bare verb port at a hecksagon's root registers the same way a bound one does", :aggregate_failures do
      registry = thing_registry("RootPortVerb") { port("Weather") { verb "provided_by" } }
      port = registry.ports["Weather"]

      expect(port.verb).to eq("provided_by")
      expect(registry.bluebook("RootPortVerb").port("Weather")).to be_nil
    end
  end

  describe "a port operation" do
    def build_operation(&block)
      registry = thing_registry("PortOp") { PortOp::Thing.port("Gateway") { operation("Do", &block) } }
      registry.bluebook("PortOp").aggregate("Thing").port("Gateway").operation("Do")
    end

    def expect_operation_refusal(message, &body)
      expect { build_operation(&body) }.to raise_error(Hecks::Bluebook::DSL::Malformed, message)
    end

    it "keeps routing out of the operation's declared attributes" do
      operation = build_operation do
        emits "Done"
      end

      expect(operation.attributes).to be_empty
    end

    it "refuses behavioral reference_to with receiver and fact guidance" do
      expect_operation_refusal(/behavioral routing.*to:.*attribute/) do
        reference_to Thing
        emits "Done"
      end
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
        build_operation { nil }
      end.to raise_error(Hecks::Bluebook::DSL::Malformed, /declares no emits/)
    end
  end

  describe "a world" do
    it "declares the realm and active version for this deployment" do
      world = world_of("Valued") do
        realm "Acme"
        latest "v2"
      end

      expect(world.to_h).to include(realm: "Acme", latest: "v2")
    end

    it "declares the database and persistence adapter every chapter defaults to" do
      world = world_of("Valued") do
        default_database "postgres://localhost/valued"
        default_adapter "PostgresEra"
      end

      expect(world.to_h).to include(default_database: "postgres://localhost/valued", default_adapter: "PostgresEra")
    end

    it "leaves both defaults undeclared when the world names neither" do
      registry = in_registry { Hecks.world("Plain") { realm "Acme" } }

      expect(registry.world("Plain").to_h).to include(default_database: nil, default_adapter: nil)
    end

    it "refuses a default database that says nothing" do
      expect { in_registry { Hecks.world("Blank") { default_database "" } } }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /default database says something/)
    end

    def posted_by_carrier_world
      world_of("Valued") do
        posted_by("Carrier") do
          office "EC1"
          attempts 3
        end
      end
    end

    it "any how-verb collects the values under it" do
      expect(posted_by_carrier_world.for_verb("posted_by")).to eq(adapter: "Carrier", office: "EC1", attempts: 3)
    end

    it "an unbound verb has no values" do
      registry = in_registry { Hecks.world("Empty") { nil } }
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

    def ask_via_registry(&extra)
      thing_registry("AskVia") do
        %w[Left Right].each do |port|
          AskVia::Thing.port(port) { asks("Check", to: Thing) { answers("Checked") and refuses("Refused") } }
        end
        instance_exec(&extra) if extra
      end
    end

    it "ask_via marks the operation the hecksagon picks on the port it names", :aggregate_failures do
      thing = ask_via_registry { AskVia::Thing.ask_via("Check", port: "Right") }.bluebook("AskVia").aggregate("Thing")

      expect(thing.port("Right").operation("Check")).to be_chosen
      expect(thing.port("Left").operation("Check")).not_to be_chosen
    end

    it "ask_via refuses an ask the port never declared" do
      expect { ask_via_registry { AskVia::Thing.ask_via("Nothing", port: "Right") } }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /names no declared ask/)
    end

    it "bind_for finds the wiring for an aggregate and verb", :aggregate_failures do
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
    def resolve_during_load
      seen = nil
      active = nil
      Hecks::Bluebook::DSL::ConstShim.with(->(name) { "resolved:#{name}" }) do
        seen = SomeUndefinedType
        active = Hecks::Bluebook::DSL::ConstShim.active?
      end
      [seen, active]
    end

    it "is inert outside a load, so an ordinary typo still raises", :aggregate_failures do
      expect(Hecks::Bluebook::DSL::ConstShim).not_to be_active
      expect { NoSuchConstantAnywhere }.to raise_error(NameError)
    end

    it "resolves unknown constants while a load is running, and restores after", :aggregate_failures do
      seen, active = resolve_during_load

      expect(seen).to eq("resolved:SomeUndefinedType")
      expect(active).to be(true)
      expect(Hecks::Bluebook::DSL::ConstShim).not_to be_active
    end
  end
end
