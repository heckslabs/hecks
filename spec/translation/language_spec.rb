require "spec_helper"
require "tmpdir"

# Layer 0 of the translation language's validation story: a written rule
# means what its author intended, or refuses loudly at load. Every
# message here is pinned byte-for-byte — refusal wording is contract,
# so a wording drift fails the suite.
RSpec.describe "the translation language" do
  Malformed = Hecks::Bluebook::DSL::Malformed

  def build_translation(&block)
    registry = Hecks::Runtime::Registry.new
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

      lineage = Hecks::Ports::Persistence::Lineage.new({}, computes: declared.computes)
      expect(lineage.explains?("price_cents")).to be(true)
      expect(lineage.computes?).to be(true)

      entry = Hecks::Ports::Persistence::Entry.new(operation: "save", id: "a1", state: { price_cents: 100 })
      expect(lineage.translate(entry).state).to eq(price_cents: 100)
    end

    it "registers a backfill with its default value, and its name counts as explained" do
      translation = build_translation do
        aggregate("Account") { backfill :tier, default: "standard" }
      end
      declared = translation.for_aggregate("Account")

      expect(declared.backfills.map { |b| [b.name, b.default] }).to eq([[:tier, "standard"]])

      lineage = Hecks::Ports::Persistence::Lineage.new({}, backfills: declared.backfills)
      expect(lineage.explains?("tier")).to be(true)
      expect(lineage.explains?("other")).to be(false)

      filled = Hecks::Ports::Persistence::Entry.new(operation: "save", id: "a1", state: { name: "Acme" })
      expect(lineage.translate(filled).state).to eq(name: "Acme", tier: "standard")

      already_there = Hecks::Ports::Persistence::Entry.new(operation: "save", id: "a1",
                                                           state: { name: "Acme", tier: "gold" })
      expect(lineage.translate(already_there).state).to eq(name: "Acme", tier: "gold")
    end
  end

  describe "Layer-0 refusals, pinned byte-for-byte" do
    def refusal_for(&block)
      build_translation(&block)
      nil
    rescue Malformed => refusal
      refusal.message
    end

    it "refuses every required-field omission with the pinned wording" do
      {
        proc { aggregate("Account") { rename nil, to: :amount } }                      => "a rename needs a source name",
        proc {
          aggregate("Account") {
            rename :cost, to: ""
          }
        }                                                                              => "a rename needs a destination name (to:)",
        proc {
          aggregate("Account") {
            move "price.cents", to: ""
          }
        }                                                                              => "a move needs a destination path (to:)",
        proc { aggregate("Account") { move "", to: "price_cents" } }                   => "a move needs a source path",
        proc {
          aggregate("Account") {
            convert "code", to: "", values: { 1 => "a" }
          }
        }                                                                              => "a convert needs a destination path (to:)",
        proc { aggregate("Account") { convert "", to: "code", values: { 1 => "a" } } } => "a convert needs a source path",
        proc {
          aggregate("Account") {
            convert "code", to: "code", values: {}
          }
        }                                                                              => "a convert needs a values: table",
        proc {
          aggregate("Account") {
            convert "code", to: "code", values: nil
          }
        }                                                                              => "a convert needs a values: table",
        proc { aggregate("Account") { drop "" } }                                      => "a drop needs a name",
        proc {
          aggregate("Account") {
            retype "", to: "Cash"
          }
        }                                                                              => "a retype needs a source type name",
        proc {
          aggregate("Account") {
            retype "Money", to: ""
          }
        }                                                                              => "a retype needs a destination type name (to:)",
        proc {
          aggregate("Account") {
            compute "price_cents", to: "", sql: "x"
          }
        }                                                                              => "a compute needs a destination path (to:)",
        proc { aggregate("Account") { compute "", to: "price_dollars", sql: "x" } }    => "a compute needs a source path",
        proc {
          aggregate("Account") {
            compute "price_cents", to: "price_dollars", sql: ""
          }
        }                                                                              => "a compute needs its sql: expression",
        proc { aggregate("Account") { backfill "", default: "x" } }                    => "a backfill needs a name",
        proc {
          aggregate("Account") {
            backfill :tier, default: nil
          }
        }                                                                              => "a backfill needs a default: value",
        proc {
          retired ""
        }                                                                              => "a retired needs an aggregate name",
        proc {
          aggregate("")
        }                                                                              => "an aggregate translation needs a name"
      }.each do |declaration, wanted|
        expect(refusal_for(&declaration)).to eq(wanted)
      end
    end

    it "refuses a translation whose own header says nothing" do
      registry = Hecks::Runtime::Registry.new
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
      # WordGate (item #13's remaining builders) replaced the builder's
      # own hand-written method_missing — a word admitted SOMEWHERE ELSE
      # in the grammar (Aggregate context) but not inside a
      # TranslationAggregate body gets WordGate's own richer, table-
      # driven refusal, naming this context's real legal words.
      expect(refusal_for { aggregate("Account") { identified_by :cost } })
        .to eq("'identified_by' is not a word TranslationAggregate admits — legal words here: backfill, " \
               "compute, convert, drop, move, rekey, rename, retype, unresolved")

      # A genuine typo, admitted NOWHERE in the whole grammar — WordGate
      # steps aside entirely for these (word_gate.rb's own comment), so
      # this is Ruby's own plain NoMethodError, not a translation-level
      # refusal `refusal_for` (which only rescues Malformed) can catch.
      expect { build_translation { aggregate("Account") { renmae :cost, to: :amount } } }
        .to raise_error(NoMethodError, /renmae/)
      expect { build_translation { banana "Account" } }
        .to raise_error(NoMethodError, /banana/)
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
      lineage = Hecks::Ports::Persistence::Lineage.new(
        declared.renames, declared.moves, declared.converts, declared.drops, retypes: declared.retypes
      )

      expect(lineage.retype?("Money", "Cash")).to be(true)
      expect(lineage.retype?("Cash", "Money")).to be(false)

      entry = Hecks::Ports::Persistence::Entry.new(
        operation: "save", id: "a1", state: { price: { "cents" => 100 } }
      )
      expect(lineage.translate(entry).state).to eq(price: { "cents" => 100 })
    end
  end

  # ADVERSARIAL, not incidental: found by deliberately constructing a
  # destination that collides with an existing value, not by any
  # example in the corpus. `state[top] ||= {}` only guards nil/false, so
  # a destination whose top segment ALREADY held a value — most
  # commonly a reference, stored as a bare scalar id — sailed straight
  # through to `state[top][member] =`, i.e. `"team-1"["detail"] =` on a
  # plain Ruby String, raising an unrelated-looking IndexError instead
  # of the clean, named refusal every other "this would lose data
  # silently" case in this language gets (see convert's own refusal,
  # the identical shape). The refusal wording is pinned —
  # this spec pins the in-memory half; spec/adapters/postgres_lineage_spec.rb
  # pins the SQL half through a real mint.
  describe "a move/convert whose destination collides with an existing non-object value" do
    it "refuses by name instead of crashing with an unrelated error" do
      translation = build_translation do
        aggregate("Account") { move "amount.cents", to: "team_ref.detail" }
      end
      declared = translation.for_aggregate("Account")
      lineage = Hecks::Ports::Persistence::Lineage.new(
        declared.renames, declared.moves, declared.converts, declared.drops
      )
      entry = Hecks::Ports::Persistence::Entry.new(
        operation: "save", id: "a1", state: { amount: { "cents" => 500 }, team_ref: "team-1" }
      )

      expect { lineage.translate(entry) }.to raise_error(
        Hecks::Runtime::WiringError,
        "cannot move amount.cents to: team_ref.detail: team_ref already holds \"team-1\", not a value " \
        "this can nest under — moving into it would discard that value silently. Rename or drop team_ref first."
      )
    end

    it "a destination nesting under an EXISTING OBJECT sibling is unaffected — only a non-object collides" do
      translation = build_translation do
        aggregate("Account") { move "amount.cents", to: "kind.stashed" }
      end
      declared = translation.for_aggregate("Account")
      lineage = Hecks::Ports::Persistence::Lineage.new(
        declared.renames, declared.moves, declared.converts, declared.drops
      )
      entry = Hecks::Ports::Persistence::Entry.new(
        operation: "save", id: "a1", state: { amount: { "cents" => 500 }, kind: { "value" => "biz" } }
      )

      expect(lineage.translate(entry).state).to eq(kind: { "value" => "biz", "stashed" => 500 })
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

    def check_era!(source, translation_source: nil)
      Dir.mktmpdir do |dir|
        domain_dir = File.join(dir, "bluebook")
        FileUtils.mkdir_p(domain_dir)
        File.write(File.join(domain_dir, "guarded.bluebook"), GUARDED_V1)

        registry = Hecks::Runtime::Registry.new(root: dir)
        eval_bluebook(registry, GUARDED_V1, File.join(domain_dir, "guarded.bluebook"))
        Hecks::Runtime::EraGuard.check!(registry, domain_dir)

        File.write(File.join(domain_dir, "guarded.bluebook"), source)
        drifted = Hecks::Runtime::Registry.new(root: dir)
        eval_bluebook(drifted, source, File.join(domain_dir, "guarded.bluebook"))
        if translation_source
          Hecks.with_registry(drifted) { eval(translation_source) }
        end
        Hecks::Runtime::EraGuard.check!(drifted, domain_dir)
      end
    end

    it "a bare type rename refuses, and names retype among the remedies" do
      expect { check_era!(GUARDED_RETYPED) }.to raise_error(
        Hecks::Runtime::WiringError,
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
          identified_by :label

          attribute :label, Label

          value_object "Label" do
            attribute :value, String
          end
        end
      end'

      expect { check_era!(gone) }.to raise_error(
        Hecks::Runtime::WiringError,
        /Account existed and now doesn't, and nothing declares was: "Account"/
      )

      retired = 'Hecks.data_translation("Guarded", from: "1", to: "2") { retired "Account" }'
      expect { check_era!(gone, translation_source: retired) }.not_to raise_error
    end

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

    it "a new required attribute with no default refuses, naming backfill among the remedies" do
      expect { check_era!(GUARDED_NEW_REQUIRED_ATTRIBUTE) }.to raise_error(
        Hecks::Runtime::WiringError,
        /:tier is new and required.*backfill :tier, default:/
      )
    end

    it "a declared backfill covers a new required attribute" do
      translation = <<~RUBY
        Hecks.data_translation("Guarded", from: "1", to: "2") do
          aggregate("Account") { backfill :tier, default: "standard" }
        end
      RUBY
      expect { check_era!(GUARDED_NEW_REQUIRED_ATTRIBUTE, translation_source: translation) }.not_to raise_error
    end

    it "a new OPTIONAL attribute needs no translation at all" do
      optional = 'Hecks.bluebook "Guarded" do
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
      end'

      expect { check_era!(optional) }.not_to raise_error
    end
  end
end
