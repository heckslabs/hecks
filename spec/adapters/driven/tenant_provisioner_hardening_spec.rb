require "spec_helper"
require "tmpdir"
require_relative "../../../lib/hecks/adapters/driven/tenant_provisioner"

# The overlay is a Ruby-evaluated file named after the slug, so every value is validated and
# written as a string literal, and the path stays under `<directory>/environments/`.
RSpec.describe Hecks::Adapters::TenantProvisioner, "#write_overlay" do
  let(:adapter) { described_class.new }
  let(:tenant) do
    { slug: "acme", domain: "Scratch", realm: "Acme", schema: "acme", database: "hecks_tenants" }
  end

  around do |example|
    Dir.mktmpdir("provisioner") do |dir|
      @dir = dir
      example.run
    end
  end

  it "accepts bare arguments" do
    answer = adapter.write_overlay(**tenant, directory: @dir)

    expect(answer.fetch(:output)[:value]).to eq("wrote #{File.join(@dir, "environments/acme.world")}\n")
  end

  {
    slug: "ok\n../../../../escaped", schema: "ok\nx", domain: "D\nsystem(1)",
    realm: "R\"\nsystem(1)", database: "x\"\nsystem(\"id\")\n#", adapter: "A\nB"
  }.each do |field, hostile|
    it "refuses a #{field} that spans lines or carries code, and writes nothing", :aggregate_failures do
      args = tenant.merge(field => hostile, directory: @dir)

      expect { adapter.write_overlay(**args) }.to raise_error(described_class::Refused)
      expect(Dir.glob(File.join(@dir, "**/*"))).to eq([])
    end
  end

  it "refuses a directory that does not exist, and creates nothing", :aggregate_failures do
    missing = File.join(@dir, "no", "such", "domain")

    expect { adapter.write_overlay(**tenant, directory: missing) }
      .to raise_error(described_class::Refused, /not an existing domain directory/)
    expect(File.exist?(File.join(@dir, "no"))).to be(false)
  end

  it "refuses a slug that climbs out of environments/, even without a newline" do
    expect { adapter.write_overlay(**tenant, slug: "../escaped", directory: @dir) }
      .to raise_error(described_class::Refused)
  end

  it "writes a URL database as a string literal that evaluates back to itself" do
    url = "postgres://u:p\#{x}@h:5432/db?sslmode=require"
    adapter.write_overlay(**tenant, database: url, directory: @dir)

    line = File.readlines(File.join(@dir, "environments/acme.world")).grep(/database/).first
    expect(eval(line.sub("database", "").strip)).to eq(url)
  end
end
