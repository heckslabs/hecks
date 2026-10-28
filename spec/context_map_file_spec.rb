require "spec_helper"
require "hecks/fuzzing/isolated_boot"
require "hecks/cli/model_check"

# The `.contextmap` file kind (ADR 0135): its top-level word builds a ContextMap, a boot registers
# it, and `model_check` holds it to the wiring it covers.
RSpec.describe "a .contextmap file" do
  def build(&) = Hecks::Bluebook::DSL::ContextMapBuilder.build("Shop", &)

  def build_with_bare_relate
    build do
      context "A"
      relate as: :conformist
    end
  end

  describe "the Hecks.context_map word" do
    let(:shop) do
      build do
        context "Ordering", team: "storefront"
        context "Billing"
        relate "Billing" => "Ordering", as: :customer_supplier, published: %w[InvoicePaid]
        separate_ways "Billing", "Ordering"
      end
    end

    it "builds the contexts and the relationship with its published events", :aggregate_failures do
      expect(shop.contexts.map(&:team)).to eq(["storefront", nil])
      expect(shop.relationships.first.published).to eq(%w[InvoicePaid])
    end

    it "keeps a pair declared apart, whichever way it was written" do
      expect(shop.separate?("Ordering", "Billing")).to be(true)
    end

    it "refuses a relationship of an unknown kind" do
      expect { build { relate "A" => "B", as: :friendship } }.to raise_error(ArgumentError, /unknown relationship kind/)
    end

    it "refuses a relationship naming a context it does not declare" do
      expect { build { relate "A" => "B", as: :conformist } }.to raise_error(ArgumentError, /does not declare/)
    end

    it "refuses a relate that names no single pair" do
      expect { build_with_bare_relate }.to raise_error(ArgumentError, /one "Upstream"/)
    end
  end

  describe "outside a boot" do
    it "refuses, as every other declaration word does" do
      expect { Hecks.context_map("Shop") { context "Ordering" } }.to raise_error(Hecks::LoadOutsideBoot)
    end
  end

  describe "model_check" do
    let(:registry) do
      Hecks::Fuzzing::IsolatedBoot.call("examples/banking") { |copy| return Hecks.boot(copy).registry }
    end

    let(:checker) { Object.new.extend(Hecks::CLI::ModelCheck::Examination) }

    def findings = checker.send(:context_map_findings, [["banking", registry]], {})

    def declare_banking_without_compliance
      map = registry.context_map("Banking")
      kept = map.relationships.reject { |rel| rel.upstream == "Compliance" }
      registry.add_context_map(Hecks::Bluebook::ContextMap.new(name: "Banking", contexts: map.contexts, relationships: kept))
    end

    it "finds nothing when Banking's wiring matches its map" do
      expect(findings).to be_empty
    end

    it "reports a coupling the map no longer declares" do
      declare_banking_without_compliance
      expect(findings.map(&:kind).uniq).to eq([:undeclared_coupling])
    end
  end
end
