require "spec_helper"
require "hecksagain/query_ir"

RSpec.describe Hecksagain::QueryIR do
  describe ".constructs" do
    it "reports every real construct clean, matching spec/model_shape_conformance_spec.rb's own passing gate" do
      diffs = described_class.constructs
      expect(diffs.size).to eq(described_class::CONSTRUCTS.size)

      dirty = diffs.reject { |d| d[:missing_from_ruby].empty? && d[:unaccounted_in_ruby].empty? }
      expect(dirty).to be_empty, "reported a real gap, or drifted from Deviations: #{dirty.inspect}"
    end

    it "scopes to the names given" do
      diffs = described_class.constructs(["Entity"])
      expect(diffs.map { |d| d[:name] }).to eq(["Entity"])
    end

    it "refuses a construct the language does not declare" do
      expect { described_class.constructs(["Nonsense"]) }.to raise_error(ArgumentError, /no such construct/)
    end
  end

  describe ".duplicates" do
    it "finds a real, known corpus duplication — Account's Money/PositiveMoney currency check" do
      groups = described_class.duplicates(domains: [File.join(InMemoryDomain::ROOT, "examples/banking")], include_meta: false)
      currency = groups.find { |g| g[:description] == "a currency is a three-letter code" }

      expect(currency).not_to be_nil
      expect(currency[:kind]).to eq("invariant")
      expect(currency[:locations]).to contain_exactly("Account::Money (declared)", "Account::PositiveMoney (declared)")
    end

    # THE TRICKIEST PART OF THIS TOOL — a rule's OWN OBJECT IDENTITY
    # carries no signal by the time any caller reads the registry.
    # `MetaValidator.call` (S14) judges every bluebook by dispatching
    # its own IR into the self-hosted grammar, then rebuilds the whole
    # graph fresh from flat rows (`Assembly.call`) — so a bare
    # `given("x")` reference and its owner's own block declaration,
    # the SAME Ruby object at DSL build time, are already two distinct
    # objects by the time `collect_rules` reads them back. Verified
    # live: `Account`'s OWN "customer is active" given, referenced
    # bare by `Account.Open`/`Account.Credit`/etc., comes back as N
    # distinct objects, not one — this dedup has to work WITHOUT
    # identity, by recognising that every one of those commands shares
    # the SAME OWNER (`Account`), which already carries its own
    # "(declared)" entry for it.
    #
    # `Account`'s "customer is active" is also NOT the whole story:
    # `SafeDepositBox` and `OnboardingCase` each independently declare
    # their OWN "customer is active" with the identical canonical text
    # — three genuinely separate declarations, real corpus duplication
    # the tool is right to surface (`bin/query_ir duplicates`'s own
    # live output lists all three). This test scopes to `Account`
    # alone precisely to isolate "one owner, many referencing
    # commands" from that separate, real, cross-aggregate case.
    it "does not flag a single owner's own commands referencing its declared given as N fresh duplicates" do
      raw = described_class.send(:collect_rules, Hecksagain::Codemod.load_bluebook(
                                                   InMemoryDomain::BANKING_BLUEBOOK_DIR
                                                 ))
      account_given = raw.select do |r|
        r.kind == "given" && r.description == "customer is active" &&
          r.canonical == "customer.status == \"active\"" &&
          (r.location == "Account (declared)" || r.location.start_with?("Account."))
      end

      expect(account_given.size).to be > 1 # Account's own declaration, plus every command that references it

      groups = described_class.duplicates(domains: [File.join(InMemoryDomain::ROOT, "examples/banking")], include_meta: false)
      customer_active = groups.find do |g|
        g[:kind] == "given" && g[:description] == "customer is active" &&
          g[:canonical] == "customer.status == \"active\"" &&
          g[:locations].include?("Account (declared)")
      end

      # It shows up at all (SafeDepositBox/OnboardingCase's own
      # independent declarations make it a real group) — but every
      # location this test's own raw Account-scoped rules found is
      # named, none silently dropped just because they share an owner.
      expect(customer_active).not_to be_nil
      expect(account_given.map(&:location) - customer_active[:locations]).to be_empty
    end

    # THE NEGATIVE CASE the corpus test above can't isolate on its own
    # (Account's "customer is active" always shows up, because
    # SafeDepositBox/OnboardingCase genuinely duplicate it too) —
    # `declaration_count` (the private tally `duplicates` filters on)
    # exercised directly: one owner's own declaration plus every
    # command under THAT SAME owner referencing it by name is ONE real
    # declaration, not N, and does not clear the ">1" bar alone.
    it "counts one owner's declaration plus its own commands' references as a single declaration" do
      rules = [
        described_class::Rule.new(kind: "given", description: "x", canonical: "x", location: "Account (declared)"),
        described_class::Rule.new(kind: "given", description: "x", canonical: "x", location: "Account.Open"),
        described_class::Rule.new(kind: "given", description: "x", canonical: "x", location: "Account.Credit")
      ]

      expect(described_class.send(:declaration_count, rules)).to eq(1)
    end

    it "counts two commands' own un-hoisted local givens, with no owner declaration, as two declarations" do
      rules = [
        described_class::Rule.new(kind: "given", description: "x", canonical: "x", location: "Account.Open"),
        described_class::Rule.new(kind: "given", description: "x", canonical: "x", location: "Transfer.Send")
      ]

      expect(described_class.send(:declaration_count, rules)).to eq(2)
    end
  end

  describe ".impact_preview" do
    it "reports a fully-propagated field's real touchpoints all present — Aggregate#preconditions" do
      preview = described_class.impact_preview("Aggregate", "preconditions")

      expect(preview[:name]).to eq("Aggregate")
      expect(preview[:field]).to eq("preconditions")
      by_touchpoint = preview[:touchpoints].to_h { |t| [t[:touchpoint], t[:present]] }
      expect(by_touchpoint.values).to all(eq(true))
      expect(by_touchpoint.keys).to include("meta-domain grammar declares it", "Reconstruction's hand-typed method reads it")
    end

    it "reports a field that names nothing real as absent everywhere it applies" do
      preview = described_class.impact_preview("Aggregate", "totally_unclaimed_field_name")
      applicable = preview[:touchpoints].reject { |t| t[:present].nil? }

      expect(applicable).not_to be_empty
      expect(applicable).to all(include(present: false))
    end

    # Reconstruction's hand-typed aggregate(row)/entity(row) are the
    # ONLY two — every other construct genuinely has no method for this
    # touchpoint to ask about, so it must read `nil` ("does not apply"),
    # never collapse into `false` ("not done yet") — those mean
    # different things to someone reading this mid-round.
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
    it "renders yes/NOT YET/n/a and a summary count of applicable touchpoints only" do
      text = described_class.format_impact_preview(described_class.impact_preview("Command", "givens"))

      expect(text).to include("== Command#givens ==")
      expect(text).to match(/\[\s*yes\]/)
      expect(text).to match(/\[\s*n\/a\]/)
      expect(text).to match(%r{\d+/\d+ applicable touchpoint\(s\)})
    end
  end

  describe ".format_constructs" do
    it "renders a clean diff without a MISSING/UNACCOUNTED line" do
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
