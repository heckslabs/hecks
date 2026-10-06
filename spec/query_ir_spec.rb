require "spec_helper"
require "hecks/query_ir"

RSpec.describe Hecks::QueryIR do
  describe ".constructs" do
    it "scopes to the names given" do
      diffs = described_class.constructs(["Entity"])
      expect(diffs.map { |d| d[:name] }).to eq(["Entity"])
    end

    it "refuses a construct the language does not declare" do
      expect { described_class.constructs(["Nonsense"]) }.to raise_error(ArgumentError, /no such construct/)
    end
  end

  describe ".duplicates" do
    def banking_duplicates
      described_class.duplicates(domains: [File.join(InMemoryDomain::ROOT, "examples/banking")], include_meta: false)
    end

    def account_customer_active_rules
      raw = described_class.send(:collect_rules, Hecks::Codemod.load_bluebook(InMemoryDomain::BANKING_BLUEBOOK_DIR))
      raw.select do |r|
        r.kind == "given" && r.description == "customer is active" &&
          r.canonical == "customer_status == \"active\"" &&
          (r.location == "Account (declared)" || r.location.start_with?("Account."))
      end
    end

    def customer_active_group
      banking_duplicates.find do |g|
        g[:kind] == "given" && g[:description] == "customer is active" &&
          g[:canonical] == "customer_status == \"active\"" &&
          g[:locations].include?("Account (declared)")
      end
    end

    def given_rule(location)
      described_class::Rule.new(kind: "given", description: "x", canonical: "x", location: location)
    end

    it "finds a real, known corpus duplication — Account's Money/PositiveMoney currency check", :aggregate_failures do
      currency = banking_duplicates.find { |g| g[:description] == "a currency is a three-letter code" }

      expect(currency).not_to be_nil
      expect(currency[:kind]).to eq("invariant")
      expect(currency[:locations]).to contain_exactly("Account::Money (declared)", "Account::PositiveMoney (declared)")
    end

    # Rule object identity carries no signal: `MetaValidator.call` rebuilds the graph from flat
    # rows, so a bare `given("x")` reference and its owner's declaration are distinct objects
    # by the time `collect_rules` reads them. Dedup must use the shared owner (`Account`).
    # Scoped to `Account` to isolate that from the real duplication in `SafeDepositBox` and
    # `OnboardingCase`.
    it "reads an owner's own declaration plus every command referencing it as separate rules" do
      # Account's own declaration, plus every command that references it
      expect(account_customer_active_rules.size).to be > 1
    end

    it "does not flag a single owner's own commands referencing its declared given as N fresh duplicates", :aggregate_failures do
      customer_active = customer_active_group

      # SafeDepositBox/OnboardingCase declare the same given with identical canonical text, so one
      # merged group must still name every Account-scoped location.
      expect(customer_active).not_to be_nil
      expect(account_customer_active_rules.map(&:location) - customer_active[:locations]).to be_empty
    end

    # Exercises the private `declaration_count` directly: an owner's declaration plus its own
    # commands' references is one declaration, not N.
    it "counts one owner's declaration plus its own commands' references as a single declaration" do
      rules = ["Account (declared)", "Account.Open", "Account.Credit"].map { |location| given_rule(location) }

      expect(described_class.send(:declaration_count, rules)).to eq(1)
    end

    it "counts two commands' own un-hoisted local givens, with no owner declaration, as two declarations" do
      rules = ["Account.Open", "Transfer.Send"].map { |location| given_rule(location) }

      expect(described_class.send(:declaration_count, rules)).to eq(2)
    end
  end

  describe ".impact_preview" do
    it "reports a fully-propagated field's real touchpoints all present — Aggregate#preconditions", :aggregate_failures do
      preview = described_class.impact_preview("Aggregate", "preconditions")
      by_touchpoint = preview[:touchpoints].to_h { |t| [t[:touchpoint], t[:present]] }

      expect([preview[:name], preview[:field]]).to eq(["Aggregate", "preconditions"])
      expect(by_touchpoint.values).to all(be(true))
      expect(by_touchpoint.keys).to include("meta-domain grammar declares it", "Reconstruction's hand-typed method reads it")
    end

    it "reports a field that names nothing real as absent everywhere it applies", :aggregate_failures do
      preview = described_class.impact_preview("Aggregate", "totally_unclaimed_field_name")
      applicable = preview[:touchpoints].reject { |t| t[:present].nil? }

      expect(applicable).not_to be_empty
      expect(applicable).to all(include(present: false))
    end

    # A construct with no hand-typed method must read `nil` (n/a), never `false` (not done).
    it "reports Reconstruction's touchpoint as not-applicable (nil), not false, for a construct with no hand-typed method" do
      preview = described_class.impact_preview("Command", "givens")
      reconstruction = preview[:touchpoints].find { |t| t[:touchpoint] == "Reconstruction's hand-typed method reads it" }

      expect(reconstruction[:present]).to be_nil
    end

    it "refuses a construct the language does not declare" do
      expect { described_class.impact_preview("Nonsense", "field") }.to raise_error(ArgumentError, /no such construct/)
    end
  end

  describe ".format_impact_preview" do
    it "renders yes/NOT YET/n/a and a summary count of applicable touchpoints only", :aggregate_failures do
      text = described_class.format_impact_preview(described_class.impact_preview("Command", "givens"))

      expect(text).to include("== Command#givens ==")
      expect(text).to match(/\[\s*yes\]/)
      expect(text).to match(%r{\[\s*n/a\]})
      expect(text).to match(%r{\d+/\d+ applicable touchpoint\(s\)})
    end
  end

  describe ".format_constructs" do
    it "renders a clean diff without a MISSING/UNACCOUNTED line", :aggregate_failures do
      text = described_class.format_constructs(described_class.constructs(["Entity"]))
      expect(text).to include("== Entity ==")
      expect(text).to include("clean")
      expect(text).not_to include("MISSING FROM RUBY")
    end
  end

  describe ".format_duplicates" do
    it "names how many groups and declarations, at the end" do
      text = described_class.format_duplicates(described_class.duplicates(
                                                 domains: [File.join(InMemoryDomain::ROOT,
                                                                     "examples/banking")], include_meta: false
                                               ))
      expect(text).to match(/\d+ duplicate group\(s\), \d+ declarations total/)
    end

    it "says so plainly when nothing duplicates" do
      expect(described_class.format_duplicates([])).to eq("no duplicate given/invariant/ensures rule found")
    end
  end
end
