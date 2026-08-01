require "spec_helper"
require "tmpdir"

# Layer 0 of the translation language's validation story: a written rule
# means what its author intended, or refuses loudly at load. Every
# message here is pinned byte-for-byte — the Rust parser raises the SAME
# strings (rust/src/bluebook/translation/parser.rs asserts them in its
# own tests), so a wording drift in either runtime fails a suite.
RSpec.describe "the translation language" do
  Malformed = Hecksagain::Bluebook::DSL::Malformed

  def build_translation(&block)
    registry = Hecksagain::Runtime::Registry.new
    Hecks.with_registry(registry) { Hecks.data_translation("Lineage", from: "1", to: "2", &block) }
    registry.translations.first
  end

  describe "the rule vocabulary" do
    it "registers retype pairs beside the original four rule kinds" do
      translation = build_translation do
        aggregate("Account") { retype "Money", to: "Cash" }
      end

      account = translation.for_aggregate("Account")
      expect(account.retypes.map { |retype| [retype.from, retype.to] }).to eq([["Money", "Cash"]])
    end

    it "registers retired aggregates at the domain level" do
      translation = build_translation { retired "Ledger" }
      expect(translation.retired).to eq(["Ledger"])
    end

    it "registers a compute with its SQL expression, and its from path counts as explained" do
      translation = build_translation do
        aggregate("Account") { compute "price_cents", to: "price_dollars", sql: "price_cents::numeric / 100" }
      end
      declared = translation.for_aggregate("Account")

      expect(declared.computes.map { |c| [c.from, c.to, c.sql] })
        .to eq([["price_cents", "price_dollars", "price_cents::numeric / 100"]])

      lineage = Hecksagain::Ports::Persistence::Lineage.new({}, computes: declared.computes)
      expect(lineage.explains?("price_cents")).to be(true)
      expect(lineage.computes?).to be(true)

      entry = Hecksagain::Ports::Persistence::Entry.new(operation: "save", id: "a1", state: { price_cents: 100 })
      expect(lineage.translate(entry).state).to eq(price_cents: 100)
    end
  end

  describe "Layer-0 refusals, byte-identical in both runtimes" do
    def refusal_for(&block)
      build_translation(&block)
      nil
    rescue Malformed => refusal
      refusal.message
    end

    it "refuses every required-field omission with the pinned wording" do
      {
        proc { aggregate("Account") { rename nil, to: :amount } } => "a rename needs a source name",
        proc { aggregate("Account") { rename :cost, to: "" } } => "a rename needs a destination name (to:)",
        proc { aggregate("Account") { move "price.cents", to: "" } } => "a move needs a destination path (to:)",
        proc { aggregate("Account") { move "", to: "price_cents" } } => "a move needs a source path",
        proc { aggregate("Account") { convert "code", to: "", values: { 1 => "a" } } } => "a convert needs a destination path (to:)",
        proc { aggregate("Account") { convert "", to: "code", values: { 1 => "a" } } } => "a convert needs a source path",
        proc { aggregate("Account") { convert "code", to: "code", values: {} } } => "a convert needs a values: table",
        proc { aggregate("Account") { convert "code", to: "code", values: nil } } => "a convert needs a values: table",
        proc { aggregate("Account") { drop "" } } => "a drop needs a name",
        proc { aggregate("Account") { retype "", to: "Cash" } } => "a retype needs a source type name",
        proc { aggregate("Account") { retype "Money", to: "" } } => "a retype needs a destination type name (to:)",
        proc { aggregate("Account") { compute "price_cents", to: "", sql: "x" } } => "a compute needs a destination path (to:)",
        proc { aggregate("Account") { compute "", to: "price_dollars", sql: "x" } } => "a compute needs a source path",
        proc { aggregate("Account") { compute "price_cents", to: "price_dollars", sql: "" } } => "a compute needs its sql: expression",
        proc { retired "" } => "a retired needs an aggregate name",
        proc { aggregate("") } => "an aggregate translation needs a name"
      }.each do |declaration, wanted|
        expect(refusal_for(&declaration)).to eq(wanted)
      end
    end

    it "refuses a translation whose own header says nothing" do
      registry = Hecksagain::Runtime::Registry.new
      Hecks.with_registry(registry) do
        expect { Hecks.data_translation("", from: "1", to: "2") }
          .to raise_error(Malformed, "a translation names no domain")
        expect { Hecks.data_translation("Lineage", from: "", to: "2") }
          .to raise_error(Malformed, "Lineage's translation says nothing about its origin era (from:)")
        expect { Hecks.data_translation("Lineage", from: "1", to: "") }
          .to raise_error(Malformed, "Lineage's translation says nothing about its destination era (to:)")
      end
    end

    it "refuses an unknown rule rather than skipping it" do
      expect(refusal_for { aggregate("Account") { renmae :cost, to: :amount } })
        .to eq("a translation rule must be rename, move, convert, drop, retype, compute, or unresolved — got 'renmae'")
      expect(refusal_for { banana "Account" })
        .to eq("a translation does not understand 'banana' — it declares aggregate blocks and retired aggregates")
    end

    it "an unresolved placeholder can only boot into a refusal, never a guess" do
      expect(refusal_for { aggregate("Account") { unresolved :cost, candidates: [:amount, :price_cents] } })
        .to eq("Account's translation leaves :cost unresolved (candidates: :amount, :price_cents) — " \
               "replace unresolved with a rename, move, convert, or drop before booting.")

      expect(refusal_for { aggregate("Account") { unresolved "price.currency", candidates: [] } })
        .to eq("Account's translation leaves \"price.currency\" unresolved (no candidate matched — " \
               "consider drop, or compute on Postgres) — replace unresolved with a real rule before booting.")
    end
  end

  describe "lineage semantics for the new rule kinds" do
    it "retype declares a type-name pair and moves no data" do
      translation = build_translation do
        aggregate("Account") { retype "Money", to: "Cash" }
      end
      declared = translation.for_aggregate("Account")
      lineage = Hecksagain::Ports::Persistence::Lineage.new(
        declared.renames, declared.moves, declared.converts, declared.drops, retypes: declared.retypes
      )

      expect(lineage.retype?("Money", "Cash")).to be(true)
      expect(lineage.retype?("Cash", "Money")).to be(false)

      entry = Hecksagain::Ports::Persistence::Entry.new(
        operation: "save", id: "a1", state: { price: { "cents" => 100 } }
      )
      expect(lineage.translate(entry).state).to eq(price: { "cents" => 100 })
    end
  end

  describe "EraGuard with the new rule kinds" do
    def eval_bluebook(registry, source, path)
      loading = Hecksagain::Ports::Loading.bootstrap
      Hecksagain.with_registry(registry) do
        loading.load_library
        Kernel.eval(source, TOPLEVEL_BINDING, path, 1)
      end
    end

    GUARDED_V1 = <<~BLUEBOOK.freeze
      Hecks.bluebook "Guarded" do
        aggregate "Account" do
          identified_by { balance.cents }

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
          identified_by { balance.cents }

          attribute :balance, Cash

          value_object "Cash" do
            attribute :cents, Integer
          end
        end
      end
    BLUEBOOK

    def check_era!(source, translation_source: nil)
      Dir.mktmpdir do |dir|
        domain_dir = File.join(dir, "bluebook")
        FileUtils.mkdir_p(domain_dir)
        File.write(File.join(domain_dir, "guarded.bluebook"), GUARDED_V1)

        registry = Hecksagain::Runtime::Registry.new(root: dir)
        eval_bluebook(registry, GUARDED_V1, File.join(domain_dir, "guarded.bluebook"))
        Hecksagain::Runtime::EraGuard.check!(registry, domain_dir)

        File.write(File.join(domain_dir, "guarded.bluebook"), source)
        drifted = Hecksagain::Runtime::Registry.new(root: dir)
        eval_bluebook(drifted, source, File.join(domain_dir, "guarded.bluebook"))
        if translation_source
          Hecksagain.with_registry(drifted) { eval(translation_source) }
        end
        Hecksagain::Runtime::EraGuard.check!(drifted, domain_dir)
      end
    end

    it "a bare type rename refuses, and names retype among the remedies" do
      expect { check_era!(GUARDED_RETYPED) }.to raise_error(
        Hecksagain::Runtime::WiringError,
        /not explained by any rename, move, convert, retype, or drop/
      )
    end

    it "a declared retype covers the type-name pair" do
      translation = <<~RUBY
        Hecks.data_translation("Guarded", from: "1", to: "2") do
          aggregate("Account") { retype "Money", to: "Cash" }
        end
      RUBY
      expect { check_era!(GUARDED_RETYPED, translation_source: translation) }.not_to raise_error
    end

    it "a vanished aggregate refuses unless retired declares it gone" do
      gone = 'Hecks.bluebook "Guarded" do
        aggregate "Vault" do
          identified_by { label.value }

          attribute :label, Label

          value_object "Label" do
            attribute :value, String
          end
        end
      end'

      expect { check_era!(gone) }.to raise_error(
        Hecksagain::Runtime::WiringError,
        /Account existed and now doesn't, and nothing declares was: "Account"/
      )

      retired = 'Hecks.data_translation("Guarded", from: "1", to: "2") { retired "Account" }'
      expect { check_era!(gone, translation_source: retired) }.not_to raise_error
    end
  end
end
