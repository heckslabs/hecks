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

  it "writes environments/<slug>.world under the directory, and says where" do
    Dir.mktmpdir("provisioner") do |dir|
      answer = adapter.write_overlay(**tenant, adapter: { value: "Sqlite" }, directory: { value: dir })

      path = File.join(dir, "environments/acme.world")
      expect(answer.dig(:output, :value)).to eq("wrote #{path}\n")
      expect(answer.fetch(:slug)).to eq(value: "acme")
      expect(File.read(path)).to include('realm "Acme"', 'persisted_by("Sqlite")', 'schema   "acme"')
    end
  end

  it "binds PostgresEra when the record names no adapter" do
    Dir.mktmpdir("provisioner") do |dir|
      adapter.write_overlay(**tenant, adapter: nil, directory: { value: dir })

      expect(File.read(File.join(dir, "environments/acme.world"))).to include('persisted_by("PostgresEra")')
    end
  end

  it "ignores the record's other fields" do
    Dir.mktmpdir("provisioner") do |dir|
      expect { adapter.write_overlay(**tenant, directory: { value: dir }, status: "requested", output: nil, refusal: nil) }
        .not_to raise_error
    end
  end
end
