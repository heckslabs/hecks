require "spec_helper"
require "hecks/ports/persistence/plugins/era"

# Layer 0 of the translation language: a written rule means what its author intended or refuses
# loudly at load. Refusal wording is pinned byte-for-byte.
RSpec.describe "the translation language" do
  Malformed = Hecks::Bluebook::DSL::Malformed

  # The pinned-wording table: one declaration per omission, with the refusal it must produce. It is a
  # single hash literal rather than one `it` per row.
  # The repo's `table` HashAlignment style would push every `=>` so far right that the
  # multi-line procs overrun LineLength.
  # rubocop:disable-next Layout/HashAlignment
  REQUIRED_FIELD_REFUSALS = {
    proc { aggregate("Account") { rename nil, to: :amount } } => "a rename needs a source name",
    proc {
      aggregate("Account") do
        rename :cost, to: ""
      end
    } => "a rename needs a destination name (to:)",
    proc {
      aggregate("Account") do
        move "price.cents", to: ""
      end
    } => "a move needs a destination path (to:)",
    proc { aggregate("Account") { move "", to: "price_cents" } } => "a move needs a source path",
    proc {
      aggregate("Account") do
        convert "code", to: "", values: { 1 => "a" }
      end
    } => "a convert needs a destination path (to:)",
    proc { aggregate("Account") { convert "", to: "code", values: { 1 => "a" } } } => "a convert needs a source path",
    proc {
      aggregate("Account") do
        convert "code", to: "code", values: {}
      end
    } => "a convert needs a values: table",
    proc {
      aggregate("Account") do
        convert "code", to: "code", values: nil
      end
    } => "a convert needs a values: table",
    proc { aggregate("Account") { drop "" } } => "a drop needs a name",
    proc {
      aggregate("Account") do
        retype "", to: "Cash"
      end
    } => "a retype needs a source type name",
    proc {
      aggregate("Account") do
        retype "Money", to: ""
      end
    } => "a retype needs a destination type name (to:)",
    proc {
      aggregate("Account") do
        compute "price_cents", to: "", sql: "x"
      end
    } => "a compute needs a destination path (to:)",
    proc { aggregate("Account") { compute "", to: "price_dollars", sql: "x" } } => "a compute needs a source path",
    proc {
      aggregate("Account") do
        compute "price_cents", to: "price_dollars", sql: ""
      end
    } => "a compute needs its sql: expression",
    proc { aggregate("Account") { backfill "", default: "x" } } => "a backfill needs a name",
    proc {
      aggregate("Account") do
        backfill :tier, default: nil
      end
    } => "a backfill needs a default: value",
    proc {
      retired ""
    } => "a retired needs an aggregate name",
    proc {
      aggregate("")
    } => "an aggregate translation needs a name"
  }.freeze

  def build_translation(&block)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) { Hecks.data_translation("Lineage", from: "1", to: "2", &block) }
    registry.translations.first
  end

  # The rules declared for the Account aggregate by the block.
  def declared_for(&rules)
    build_translation { aggregate("Account", &rules) }.for_aggregate("Account")
  end

  def entry_with(state) = Hecks::Ports::Persistence::Entry.new(operation: "save", id: "a1", state: state)

  # A lineage over the declared rules, the four original kinds positionally and the rest as options.
  def lineage_for(declared, **kinds)
    Hecks::Ports::Persistence::Lineage.new(declared.renames, declared.moves, declared.converts, declared.drops, **kinds)
  end

  describe "the rule vocabulary" do
    it "registers retype pairs beside the original four rule kinds" do
      account = declared_for { retype "Money", to: "Cash" }

      expect(account.retypes.map { |retype| [retype.from, retype.to] }).to eq([["Money", "Cash"]])
    end

    it "registers retired aggregates at the domain level" do
      translation = build_translation { retired "Ledger" }
      expect(translation.retired).to eq(["Ledger"])
    end

    describe "a compute" do
      let(:declared) { declared_for { compute "price_cents", to: "price_dollars", sql: "price_cents::numeric / 100" } }
      let(:lineage) { Hecks::Ports::Persistence::Lineage.new({}, computes: declared.computes) }

      it "registers with its SQL expression" do
        expect(declared.computes.map { |c| [c.from, c.to, c.sql] })
          .to eq([["price_cents", "price_dollars", "price_cents::numeric / 100"]])
      end

      it "counts its from path as explained", :aggregate_failures do
        expect(lineage.explains?("price_cents")).to be(true)
        expect(lineage.computes?).to be(true)
      end

      it "leaves a translated entry's state as it was" do
        expect(lineage.translate(entry_with(price_cents: 100)).state).to eq(price_cents: 100)
      end
    end

    describe "a backfill" do
      let(:declared) { declared_for { backfill :tier, default: "standard" } }
      let(:lineage) { Hecks::Ports::Persistence::Lineage.new({}, backfills: declared.backfills) }

      it "registers with its default value" do
        expect(declared.backfills.map { |b| [b.name, b.default] }).to eq([[:tier, "standard"]])
      end

      it "counts its name as explained", :aggregate_failures do
        expect(lineage.explains?("tier")).to be(true)
        expect(lineage.explains?("other")).to be(false)
      end

      it "fills a missing value with the default" do
        expect(lineage.translate(entry_with(name: "Acme")).state).to eq(name: "Acme", tier: "standard")
      end

      it "keeps a value already there" do
        expect(lineage.translate(entry_with(name: "Acme", tier: "gold")).state).to eq(name: "Acme", tier: "gold")
      end
    end
  end

  describe "Layer-0 refusals, pinned byte-for-byte" do
    def refusal_for(&block)
      build_translation(&block)
      nil
    rescue Malformed => e
      e.message
    end

    def declare_translation(domain, **eras)
      Hecks.with_registry(Hecks::Runtime::Registry.new) { Hecks.data_translation(domain, **eras) }
    end

    it "refuses every required-field omission with the pinned wording" do
      REQUIRED_FIELD_REFUSALS.each do |declaration, wanted|
        expect(refusal_for(&declaration)).to eq(wanted)
      end
    end

    it "refuses a translation naming no domain" do
      expect { declare_translation("", from: "1", to: "2") }.to raise_error(Malformed, "a translation names no domain")
    end

    it "refuses a translation saying nothing about its origin era" do
      expect { declare_translation("Lineage", from: "", to: "2") }
        .to raise_error(Malformed, "Lineage's translation says nothing about its origin era (from:)")
    end

    it "refuses a translation saying nothing about its destination era" do
      expect { declare_translation("Lineage", from: "1", to: "") }
        .to raise_error(Malformed, "Lineage's translation says nothing about its destination era (to:)")
    end

    # A word admitted elsewhere in the grammar gets WordGate's table-driven refusal naming this
    # context's legal words.
    it "refuses a rule admitted elsewhere in the grammar, naming the legal words" do
      expect(refusal_for { aggregate("Account") { identified_by :cost } })
        .to eq("'identified_by' is not a word TranslationAggregate admits — legal words here: backfill, " \
               "compute, convert, drop, move, rekey, rename, retype, unresolved")
    end

    # A word admitted nowhere in the grammar is left to Ruby's NoMethodError, which `refusal_for`
    # (Malformed only) does not rescue.
    it "leaves a word admitted nowhere in the grammar to NoMethodError", :aggregate_failures do
      expect { build_translation { aggregate("Account") { renmae :cost, to: :amount } } }
        .to raise_error(NoMethodError, /renmae/)
      expect { build_translation { banana "Account" } }
        .to raise_error(NoMethodError, /banana/)
    end

    it "an unresolved placeholder with candidates can only boot into a refusal, never a guess" do
      expect(refusal_for { aggregate("Account") { unresolved :cost, candidates: [:amount, :price_cents] } })
        .to eq("Account's translation leaves :cost unresolved (candidates: :amount, :price_cents) — " \
               "replace unresolved with a rename, move, convert, or drop before booting.")
    end

    it "an unresolved placeholder with no candidates can only boot into a refusal, never a guess" do
      expect(refusal_for { aggregate("Account") { unresolved "price.currency", candidates: [] } })
        .to eq("Account's translation leaves \"price.currency\" unresolved (no candidate matched — " \
               "consider drop, or compute on Postgres) — replace unresolved with a real rule before booting.")
    end
  end

  describe "lineage semantics for the new rule kinds" do
    let(:declared) { declared_for { retype "Money", to: "Cash" } }
    let(:lineage) { lineage_for(declared, retypes: declared.retypes) }

    it "retype declares a type-name pair", :aggregate_failures do
      expect(lineage.retype?("Money", "Cash")).to be(true)
      expect(lineage.retype?("Cash", "Money")).to be(false)
    end

    it "retype moves no data" do
      expect(lineage.translate(entry_with(price: { "cents" => 100 })).state).to eq(price: { "cents" => 100 })
    end
  end

  # Pins a destination colliding with an existing scalar (a reference id): it must refuse by name,
  # not raise IndexError from `"team-1"["detail"] =`. The SQL half is pinned in
  # spec/adapters/postgres_lineage_spec.rb.
  describe "a move/convert whose destination collides with an existing non-object value" do
    def moving_to(destination) = lineage_for(declared_for { move "amount.cents", to: destination })

    def collision_refusal
      "cannot move amount.cents to: team_ref.detail: team_ref already holds \"team-1\", not a value " \
        "this can nest under — moving into it would discard that value silently. Rename or drop team_ref first."
    end

    it "refuses by name instead of crashing with an unrelated error" do
      entry = entry_with(amount: { "cents" => 500 }, team_ref: "team-1")

      expect { moving_to("team_ref.detail").translate(entry) }
        .to raise_error(Hecks::Runtime::WiringError, collision_refusal)
    end

    it "a destination nesting under an EXISTING OBJECT sibling is unaffected — only a non-object collides" do
      entry = entry_with(amount: { "cents" => 500 }, kind: { "value" => "biz" })

      expect(moving_to("kind.stashed").translate(entry).state).to eq(kind: { "value" => "biz", "stashed" => 500 })
    end
  end

  describe "EraGuard with the new rule kinds" do
    def eval_bluebook(registry, source, path)
      loading = Hecks::Ports::Loading.bootstrap
      Hecks.with_registry(registry) do
        loading.load_library
        Kernel.eval(source, TOPLEVEL_BINDING, path, 1)
      end
    end

    GUARDED_V1 = <<~BLUEBOOK.freeze
      Hecks.bluebook "Guarded" do
        aggregate "Account" do
          identified_by :balance

          attribute :balance, Money

          value_object "Money" do
            attribute :cents, Integer
          end
        end
      end
    BLUEBOOK

    GUARDED_RETYPED = <<~BLUEBOOK.freeze
      Hecks.bluebook "Guarded" do
        aggregate "Account" do
          identified_by :balance

          attribute :balance, Cash

          value_object "Cash" do
            attribute :cents, Integer
          end
        end
      end
    BLUEBOOK

    GUARDED_VANISHED = <<~BLUEBOOK.freeze
      Hecks.bluebook "Guarded" do
        aggregate "Vault" do
          identified_by :label

          attribute :label, Label

          value_object "Label" do
            attribute :value, String
          end
        end
      end
    BLUEBOOK

    GUARDED_NEW_REQUIRED_ATTRIBUTE = <<~BLUEBOOK.freeze
      Hecks.bluebook "Guarded" do
        aggregate "Account" do
          identified_by :balance

          attribute :balance, Money
          attribute :tier, Tier

          value_object "Money" do
            attribute :cents, Integer
          end

          value_object "Tier" do
            attribute :value, String
          end
        end
      end
    BLUEBOOK

    GUARDED_NEW_OPTIONAL_ATTRIBUTE = <<~BLUEBOOK.freeze
      Hecks.bluebook "Guarded" do
        aggregate "Account" do
          identified_by :balance

          attribute :balance, Money
          attribute :tier, Tier, optional: true

          value_object "Money" do
            attribute :cents, Integer
          end

          value_object "Tier" do
            attribute :value, String
          end
        end
      end
    BLUEBOOK

    RETYPE_TRANSLATION = <<~RUBY.freeze
      Hecks.data_translation("Guarded", from: "1", to: "2") do
        aggregate("Account") { retype "Money", to: "Cash" }
      end
    RUBY

    BACKFILL_TRANSLATION = <<~RUBY.freeze
      Hecks.data_translation("Guarded", from: "1", to: "2") do
        aggregate("Account") { backfill :tier, default: "standard" }
      end
    RUBY

    RETIRE_TRANSLATION = 'Hecks.data_translation("Guarded", from: "1", to: "2") { retired "Account" }'.freeze

    def era_registry(source, path)
      registry = Hecks::Runtime::Registry.new
      eval_bluebook(registry, source, path)
      registry
    end

    # Calls EraGuard's primitives directly over two in-memory registries, as CoverageCheck does.
    def check_era!(source, translation_source: nil)
      held_bluebook = era_registry(GUARDED_V1, "guarded_v1.bluebook").bluebook("Guarded")
      drifted = era_registry(source, "guarded_v2.bluebook")
      Hecks.with_registry(drifted) { eval(translation_source) } if translation_source

      bluebook = drifted.bluebook("Guarded")
      bluebook.aggregates.each { |aggregate| guard_aggregate(drifted, bluebook, held_bluebook, aggregate) }
      Hecks::Runtime::EraGuard.check_vanished_aggregates!(drifted, bluebook, held_bluebook)
    end

    def guard_aggregate(drifted, bluebook, held_bluebook, aggregate)
      lineage = Hecks::Ports::Persistence::Lineage.for(drifted, bluebook.name, aggregate)
      held_aggregate = held_bluebook.aggregate(lineage&.ancestor_name || aggregate.name)
      refuse_gaps(bluebook, aggregate, held_aggregate, lineage) if held_aggregate
    end

    def refuse_gaps(bluebook, aggregate, held_aggregate, lineage)
      guard = Hecks::Runtime::EraGuard
      uncovered = guard.uncovered_attributes(aggregate, held_aggregate, lineage)
      guard.refuse_uncovered!(bluebook, aggregate, uncovered) unless uncovered.empty?

      unsafe = guard.unsafe_additions(aggregate, held_aggregate, lineage)
      guard.refuse_unsafe_addition!(bluebook, aggregate, unsafe) unless unsafe.empty?
    end

    it "a bare type rename refuses, and names retype among the remedies" do
      expect { check_era!(GUARDED_RETYPED) }.to raise_error(
        Hecks::Runtime::WiringError,
        /not explained by any rename, move, convert, retype, or drop/
      )
    end

    it "a declared retype covers the type-name pair" do
      expect { check_era!(GUARDED_RETYPED, translation_source: RETYPE_TRANSLATION) }.not_to raise_error
    end

    it "a vanished aggregate refuses" do
      expect { check_era!(GUARDED_VANISHED) }.to raise_error(
        Hecks::Runtime::WiringError,
        /Account existed and now doesn't, and nothing declares was: "Account"/
      )
    end

    it "a vanished aggregate is accepted once retired declares it gone" do
      expect { check_era!(GUARDED_VANISHED, translation_source: RETIRE_TRANSLATION) }.not_to raise_error
    end

    it "a new required attribute with no default refuses, naming backfill among the remedies" do
      expect { check_era!(GUARDED_NEW_REQUIRED_ATTRIBUTE) }.to raise_error(
        Hecks::Runtime::WiringError,
        /:tier is new and required.*backfill :tier, default:/
      )
    end

    it "a declared backfill covers a new required attribute" do
      expect { check_era!(GUARDED_NEW_REQUIRED_ATTRIBUTE, translation_source: BACKFILL_TRANSLATION) }.not_to raise_error
    end

    it "a new OPTIONAL attribute needs no translation at all" do
      expect { check_era!(GUARDED_NEW_OPTIONAL_ATTRIBUTE) }.not_to raise_error
    end
  end
end
