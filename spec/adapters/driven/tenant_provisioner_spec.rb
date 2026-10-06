require "spec_helper"
require "tmpdir"
require_relative "../../../lib/hecks/adapters/driven/tenant_provisioner"

# The TenantProvisioning port's adapter writes the overlay world a tenant boots under. It is asked
# through `Tenant.Provision` and `hecks deploy provision`, with the record's other fields alongside.
RSpec.describe Hecks::Adapters::TenantProvisioner do
  let(:adapter) { described_class.new }
  let(:tenant) do
    { slug: { value: "acme" }, domain: { value: "Scratch" }, realm: { value: "Acme" },
      schema: { value: "acme" }, database: { value: "hecks_tenants" } }
  end

  around do |example|
    Dir.mktmpdir("provisioner") do |dir|
      @dir = dir
      example.run
    end
  end

  def overlay_path = File.join(@dir, "environments/acme.world")

  context "with Sqlite named" do
    let(:answer) { adapter.write_overlay(**tenant, adapter: { value: "Sqlite" }, directory: { value: @dir }) }

    it "writes environments/<slug>.world under the directory, and says where" do
      expect(answer.dig(:output, :value)).to eq("wrote #{overlay_path}\n")
    end

    it "answers the slug it provisioned" do
      expect(answer.fetch(:slug)).to eq(value: "acme")
    end

    it "binds the named adapter, realm and schema in the world" do
      answer

      expect(File.read(overlay_path)).to include('realm "Acme"', 'persisted_by("Sqlite")', 'schema   "acme"')
    end
  end

  it "binds PostgresEra when the record names no adapter" do
    adapter.write_overlay(**tenant, adapter: nil, directory: { value: @dir })

    expect(File.read(overlay_path)).to include('persisted_by("PostgresEra")')
  end

  it "ignores the record's other fields" do
    expect { adapter.write_overlay(**tenant, directory: { value: @dir }, status: "requested", output: nil, refusal: nil) }
      .not_to raise_error
  end
end
