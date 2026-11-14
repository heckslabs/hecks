require "spec_helper"
require "hecks/embryonaut_bluebook"

# The delivery package Hecks vendors from Switchyard (ADR 0205): its files are the release its lock
# names, and the Hecks domain reaches its aggregates. Switchyard checks the package itself.
RSpec.describe "the vendored delivery package" do
  let(:package) { File.join(Hecks::Tools::ROOT, "lib/hecks/vendor/embryonaut_bluebooks/delivery") }
  let(:lock) { Hecks::EmbryonautBluebook::Lock.read(File.join(package, "bluebook.lock")) }

  it "holds the files its lock was written over" do
    expect(Hecks::EmbryonautBluebook::Lock.digest_of(File.join(package, "bluebook"))).to eq(lock.digest)
  end

  it "is pinned at a release tag of its own name" do
    expect(lock.tag).to eq("delivery-v#{lock.version}")
  end

  it "gives the Hecks domain its Landing" do
    expect(boot_hecks_in_memory.registry.bluebook("Delivery").aggregates.map(&:name)).to include("Landing")
  end
end
