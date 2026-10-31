require "spec_helper"
require "json"
require "tmpdir"

# A `domain_module` block groups a bluebook's aggregates by the task they serve (ADR 0163). The
# grouping is a fact in the IR, one row per aggregate; it changes no aggregate, and a bluebook that
# declares no module emits as it did.
RSpec.describe "domain_module" do
  MODULE_FIXTURE = File.join(InMemoryDomain::ROOT, "spec/fixtures/domain_module.bluebook")

  def load_bluebook(path)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT,
       InMemoryDomain::MEMORY_ADAPTER, InMemoryDomain::PRISM_ADAPTER, path].each { |file| Kernel.load(file) }
    end
    registry.bluebooks.values.first
  end

  def bluebook_with(body)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "workshop.bluebook")
      File.write(path, %(Hecks.bluebook "Workshop" do\n  vision "A bench."\n#{body}\nend\n))
      load_bluebook(path)
    end
  end

  let(:workshop) { load_bluebook(MODULE_FIXTURE) }

  it "records one row per aggregate a module groups, each carrying the module's vision", :aggregate_failures do
    rows = workshop.to_h.fetch(:modules)
    expect(rows.map { |row| row.values_at(:name, :aggregate) }).to eq([%w[Make Part], ["Hand on", "Parcel"]])
    expect(rows.first[:vision]).to eq("Turn raw parts into finished ones.")
  end

  it "keeps the bluebook's own vision apart from a module's" do
    expect(workshop.vision).to eq("A bench where parts are made and then handed on.")
  end

  it "keeps a policy written inside a module the bluebook's own" do
    expect(workshop.policies.map(&:name)).to eq(["HandOnWhenFinished"])
  end

  it "leaves the modules out of the IR of a bluebook that declares none" do
    plain = load_bluebook(File.join(InMemoryDomain::ROOT, "spec/fixtures/policy_row_fields.bluebook"))
    expect(plain.to_h).not_to have_key(:modules)
  end

  it "refuses a word that describes the whole bluebook inside a module" do
    body = %(  domain_module "Make" do\n    namespace "Shop"\n  end)
    expect { bluebook_with(body) }.to raise_error(Hecks::Bluebook::DSL::Malformed, /whole bluebook/)
  end

  it "refuses a module nested in a module" do
    body = %(  domain_module "Make" do\n    domain_module "Inner" do\n    end\n  end)
    expect { bluebook_with(body) }.to raise_error(Hecks::Bluebook::DSL::Malformed, /do not nest/)
  end

  it "refuses a module that holds no aggregate" do
    body = %(  domain_module "Make" do\n    vision "Nothing here."\n  end)
    expect { bluebook_with(body) }.to raise_error(Hecks::Bluebook::DSL::Malformed, /holds no aggregate/)
  end
end
