require "spec_helper"
require "tmpdir"
require "fileutils"

# The TenantProvisioning port's adapter writes a tenant's overlay world, then boots the domain
# under it and checks it is tenant_capable (ADR 0080, section 7). The overlay binds Memory here so
# the boot needs no database.
RSpec.describe Hecks::Adapters::TenantProvisioner do
  TENANT_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "Stall" do
      aggregate "Thing" do
        identified_by :name
        attribute :name, ThingName
        value_object "ThingName" do
          attribute :value, String
          invariant("named") { !value.to_s.empty? }
        end
        command "Create" do
          attribute :name, ThingName
          sets :name
          emits "ThingCreated"
        end
      end
    end
  RUBY

  subject(:provisioner) { described_class.new }

  def in_domain
    Dir.mktmpdir("tenant_provisioner") do |dir|
      File.write(File.join(dir, "stall.bluebook"), TENANT_BLUEBOOK)
      File.write(File.join(dir, "stall.hecksagon"), %(Hecks.hecksagon "Stall" do\n  persisted_by "Memory"\nend\n))
      yield dir
    end
  end

  def establish(dir, **overrides)
    provisioner.establish(
      slug: { value: "acme" }, domain: { value: "Stall" }, realm: { value: "Acme" },
      schema: { value: "acme" }, database: { value: "stall" }, adapter: { value: "Memory" },
      directory: { value: dir }, **overrides
    )
  end

  it "writes the overlay world the tenant boots under" do
    in_domain do |dir|
      establish(dir)

      overlay = File.read(File.join(dir, "environments/acme.world"))
      expect(overlay).to include('Hecks.world "Stall"', 'realm "Acme"', 'persisted_by("Memory")',
                                 'database "stall"', 'schema   "acme"')
    end
  end

  it "answers the tenant's own identity, as it was given" do
    in_domain do |dir|
      expect(establish(dir)).to eq(slug: { value: "acme" }, domain: { value: "Stall" },
                                   realm: { value: "Acme" }, schema: { value: "acme" })
    end
  end

  it "accepts the whole record a journaled request hands it, ignoring what it does not use" do
    in_domain do |dir|
      expect { establish(dir, refusal: nil, status: "declared", id: "acme") }.not_to raise_error
    end
  end

  it "refuses a directory that does not exist, writing nothing" do
    expect { establish("/nowhere/stall") }.to raise_error(ArgumentError, %r{no such domain directory: /nowhere/stall})
  end
end
