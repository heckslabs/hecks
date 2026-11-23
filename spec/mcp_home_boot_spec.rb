require "spec_helper"
require_relative "support/role_door_kept_checkout"
require "hecks/adapters/driving/mcp"

# A read of a bluebook the home domain attaches is answered from the home domain's own boot.
RSpec.describe Hecks::Adapters::Driving::Mcp::HomeBoot do
  include RoleDoorKeptCheckout

  let(:mcp) { Hecks::Adapters::Driving::Mcp }

  before { open_checkout }

  after { close_checkout }

  def lib_path(name) = File.join(@checkout, "lib/hecks", name)

  def tenant_events
    IO.popen(["sqlite3", File.join(@store, "kept.db"), "select count(*) from events"], &:read).to_i
  end

  it "answers an attached directory as the attached bluebook" do
    expect(mcp.home_runtime(lib_path("tenancy")).first_bluebook.name).to eq("Tenancy")
  end

  it "answers neither the home directory nor a directory the home does not attach" do
    FileUtils.mkdir_p(lib_path("unattached"))
    expect([lib_path("hecks"), lib_path("unattached")].map { |path| mcp.home_runtime(path) }).to eq([nil, nil])
  end

  it "boots the home domain once for two reads" do
    runtimes = Array.new(2) { mcp.home_runtime(lib_path("tenancy")).__getobj__ }
    expect(runtimes.first).to equal(runtimes.last)
  end

  it "boots the home domain again when a file of the attached directory changes" do
    before = mcp.home_runtime(lib_path("tenancy")).__getobj__
    File.write(File.join(lib_path("tenancy"), "changed.txt"), "x")
    expect(mcp.home_runtime(lib_path("tenancy")).__getobj__).not_to equal(before)
  end

  it "reads the kept rows and writes nothing to the store" do
    written = tenant_events
    mcp.home_runtime(lib_path("tenancy")).then { |runtime| Hecks::Storehouse.state(runtime: runtime, aggregate: "Tenant", summary: "spec") }
    expect(tenant_events).to eq(written)
  end
end
