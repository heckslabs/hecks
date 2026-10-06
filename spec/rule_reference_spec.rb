require "spec_helper"
require "tmpdir"
require "hecks/codemod"

# The three resolution primitives in bluebook/dsl/rule_reference.rb, each proven on a small
# synthetic bluebook so a branch the real corpus stops exercising is still covered.
RSpec.describe "Hecks::Bluebook::DSL::RuleReference" do
  # A minimal but real bluebook proving the hash-chain's two pools (own
  # owner, then sibling entity) — trimming either entity would collapse
  # the very fallback this primitive exists to prove.
  RULE_REF_HASH_CHAIN = <<~BLUEBOOK.freeze
    Hecks.bluebook "HashChain", version: "v1" do
      aggregate "Box" do
        attribute :label, Label
        identified_by :label

        value_object "Label" do
          attribute :value, String, pattern: '[^ \\t\\n\\r]'
        end

        entity "Visit" do
          attribute :note, Label
          identified_by :note
          given("box is open") { parent.status == "open" }

          command "Log" do
            attribute :note, Label
            given("box is open")
            sets :note
            emits "Logged"
          end
        end

        entity "Key" do
          attribute :serial, Label
          identified_by :serial

          command "Return" do
            attribute :serial, Label
            given("box is open")
            sets :serial
            emits "Returned"
          end
        end

        lifecycle :status, default: "open" do
        end
      end
    end
  BLUEBOOK

  RULE_REF_HASH_CHAIN_BAD = <<~BLUEBOOK.freeze
    Hecks.bluebook "HashChainBad", version: "v1" do
      aggregate "Box" do
        attribute :label, Label
        identified_by :label

        value_object "Label" do
          attribute :value, String, pattern: '[^ \\t\\n\\r]'
        end

        entity "Key" do
          attribute :serial, Label
          identified_by :serial

          command "Return" do
            attribute :serial, Label
            given("box is open")
            sets :serial
            emits "Returned"
          end
        end

        lifecycle :status, default: "open" do
        end
      end
    end
  BLUEBOOK

  RULE_REF_TWO_CANDIDATES = <<~BLUEBOOK.freeze
    Hecks.bluebook "OwnerKeyed", version: "v1" do
      aggregate "Account" do
        attribute :label, Label
        identified_by :label
        given("customer is active") { customer.status == "active" }
        reference_to Customer

        value_object "Label" do
          attribute :value, String, pattern: '[^ \\t\\n\\r]'
        end

        command "Open" do
          given("customer is active")
          emits "Opened"
        end

        lifecycle :status, default: "open" do
        end
      end

      aggregate "Card" do
        attribute :label, Label
        identified_by :label
        given("customer is active") { account.customer.status == "active" }
        reference_to Account

        value_object "Label" do
          attribute :value, String, pattern: '[^ \\t\\n\\r]'
        end

        command "Issue" do
          given("customer is active")
          emits "Issued"
        end

        lifecycle :status, default: "issued" do
        end
      end

      aggregate "Customer" do
        attribute :status, Status
        identified_by :status

        value_object "Status" do
          attribute :value, String, pattern: '[^ \\t\\n\\r]'
        end

        command "Register" do
          emits "Registered"
        end
      end
    end
  BLUEBOOK

  # Needs a third aggregate (Box) sharing no `declared_by:` conflict, to
  # prove the unambiguous path actually resolves rather than merely never
  # hitting the ambiguous branch by omission; a minimal 2-aggregate chapter
  # wouldn't distinguish the two.
  RULE_REF_SINGLE_CANDIDATE = <<~BLUEBOOK.freeze
    Hecks.bluebook "OwnerKeyedSingle", version: "v1" do
      aggregate "Account" do
        attribute :label, Label
        identified_by :label
        given("customer is active") { customer.status == "active" }
        reference_to Customer

        value_object "Label" do
          attribute :value, String, pattern: '[^ \\t\\n\\r]'
        end

        command "Open" do
          given("customer is active")
          emits "Opened"
        end

        lifecycle :status, default: "open" do
        end
      end

      aggregate "Box" do
        attribute :label, Label
        identified_by :label
        given("customer is active")

        value_object "Label" do
          attribute :value, String, pattern: '[^ \\t\\n\\r]'
        end

        lifecycle :status, default: "vacant" do
        end
      end

      aggregate "Customer" do
        attribute :status, Status
        identified_by :status

        value_object "Status" do
          attribute :value, String, pattern: '[^ \\t\\n\\r]'
        end

        command "Register" do
          emits "Registered"
        end
      end
    end
  BLUEBOOK

  # Needs three aggregates (A, B, and an unrelated C also naming "x") to
  # prove ambiguity is about genuinely conflicting candidates, not just any
  # repeated description; a 2-aggregate fixture couldn't show that.
  RULE_REF_AMBIGUOUS = <<~BLUEBOOK.freeze
    Hecks.bluebook "Ambiguous", version: "v1" do
      aggregate "A" do
        attribute :id, Label
        identified_by :id
        given("x") { true }

        value_object "Label" do
          attribute :value, String, pattern: '[^ \\t\\n\\r]'
        end

        lifecycle :status, default: "s" do
        end
      end

      aggregate "B" do
        attribute :id, Label
        identified_by :id
        given("x") { false }

        value_object "Label" do
          attribute :value, String, pattern: '[^ \\t\\n\\r]'
        end

        lifecycle :status, default: "s" do
        end
      end

      aggregate "C" do
        attribute :id, Label
        identified_by :id
        given("x")

        value_object "Label" do
          attribute :value, String, pattern: '[^ \\t\\n\\r]'
        end

        lifecycle :status, default: "s" do
        end
      end
    end
  BLUEBOOK

  RULE_REF_SIBLING_SCAN = <<~BLUEBOOK.freeze
    Hecks.bluebook "SiblingScan", version: "v1" do
      aggregate "Account" do
        attribute :label, Label
        identified_by :label
        attribute :balance, Money

        value_object "Label" do
          attribute :value, String, pattern: '[^ \\t\\n\\r]'
        end

        value_object "Money" do
          attribute :cents, Integer
          invariant("a currency is a three-letter code") { true }
        end

        command "Open" do
          emits "Opened"
        end
      end
    end
  BLUEBOOK

  RULE_REF_SIBLING_SCAN_BAD = <<~BLUEBOOK.freeze
    Hecks.bluebook "SiblingScanBad", version: "v1" do
      aggregate "Account" do
        attribute :label, Label
        identified_by :label

        value_object "Label" do
          attribute :value, String, pattern: '[^ \\t\\n\\r]'
          invariant("nonexistent thing")
        end

        command "Open" do
          emits "Opened"
        end
      end
    end
  BLUEBOOK

  def load(source)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "smoke.bluebook")
      File.write(path, source)
      Hecks::Codemod.load_bluebook(path)
    end
  end

  def first_aggregate(registry) = registry.bluebooks.values.first.aggregates.first

  def aggregate_named(registry, name) = registry.bluebooks.values.first.aggregates.find { |a| a.hecks_name == name }

  describe "#lookup" do
    def known_primitives = %w[hash_chain owner_keyed sibling_scan]

    it "reads the REAL self-hosted table (Keyword#resolves_via) once bootstrapping is done, " \
       "the same generated data rust/parser/src/keywords.rs is generated from", :aggregate_failures do
      table = Hecks::Bluebook::MetaValidator::SyntaxBoot.call[:keywords]
      populated = table.reject { |row| row[:resolves_via].to_s == "" }

      expect(populated).not_to be_empty
      populated.each { |row| expect(known_primitives).to include(row[:resolves_via]) }
    end

    it "names a primitive every BOOTSTRAP_FALLBACK entry actually is — the ONE window " \
       "(MetaValidator.bootstrapping?) where the real table cannot be read yet" do
      Hecks::Bluebook::DSL::RuleReference::BOOTSTRAP_FALLBACK.each_value do |rule|
        expect(known_primitives).to include(rule[:resolves_via])
      end
    end
  end

  describe "#verify_resolves_via!" do
    def verify_given_resolves_via(primitive)
      Hecks::Bluebook::DSL::RuleReference.verify_resolves_via!("given", "Aggregate", primitive)
    end

    it "raises when the grammar table disagrees with what a builder is about to do", :aggregate_failures do
      Hecks::Bluebook::MetaValidator.grammar_registry # ensure bootstrapping is over

      expect(Hecks::Bluebook::MetaValidator.bootstrapping?).to be(false)
      expect { verify_given_resolves_via("hash_chain") }.to raise_error(/the grammar table and the implementation have drifted/)
      expect { verify_given_resolves_via("owner_keyed") }.not_to raise_error
    end
  end

  # Primitive 1 — CommandBuilder#given's own two-pool chain: its own
  # owner (the piece), then a sibling piece's entity-wide pool.
  describe "resolve_hash_chain (CommandBuilder#given)" do
    it "finds a match in the SECOND pool when the first has none", :aggregate_failures do
      box  = first_aggregate(load(RULE_REF_HASH_CHAIN))
      key  = box.entities.find { |e| e.hecks_name == "Key" }
      seen = key.commands.first.givens.first

      expect(seen.description).to eq("box is open")
      expect(seen.canonical).to eq('parent.status == "open"')
    end

    it "refuses when NEITHER pool in the chain has a match" do
      expect { load(RULE_REF_HASH_CHAIN_BAD) }.to raise_error(Hecks::Bluebook::DSL::Malformed, /names no precondition/)
    end
  end

  # Primitive 2 — AggregateBuilder#given's own chapter-wide, owner-keyed
  # pool: unambiguous when exactly one candidate is registered,
  # `declared_by:` required once a second, genuinely different
  # candidate registers under the same description.
  describe "resolve_owner_keyed (AggregateBuilder#given)" do
    it "resolves unambiguously when exactly one candidate is registered" do
      box = aggregate_named(load(RULE_REF_SINGLE_CANDIDATE), "Box")

      expect(box.preconditions.first.canonical).to eq('customer.status == "active"')
    end

    it "refuses AMBIGUOUS when two candidates exist and declared_by: is omitted" do
      expect { load(RULE_REF_AMBIGUOUS) }.to raise_error(Hecks::Bluebook::DSL::Malformed, /is ambiguous in this chapter/)
    end

    it "resolves the named candidate when declared_by: disambiguates" do
      card = aggregate_named(load(RULE_REF_TWO_CANDIDATES), "Card")

      expect(card.preconditions.first.canonical).to eq('account.customer.status == "active"')
    end
  end

  # Primitive 3 — ValueObjectBuilder#invariant's own live scan over
  # already-built sibling value objects, not a separate pool.
  describe "resolve_sibling_scan (ValueObjectBuilder#invariant)" do
    it "resolves against a sibling value object's own already-declared invariant" do
      money = first_aggregate(load(RULE_REF_SIBLING_SCAN)).value_objects.find { |vo| vo.hecks_name == "Money" }

      expect(money.invariants.first.description).to eq("a currency is a three-letter code")
    end

    it "refuses when no sibling value object declares the named invariant" do
      expect { load(RULE_REF_SIBLING_SCAN_BAD) }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /names no rule a sibling value/)
    end
  end
end
