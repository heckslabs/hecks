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

  # The package owns the repository verbs: Hecks declares none of them beside it, so a declaration
  # is changed in the package and nowhere else.
  describe "what Hecks itself still declares" do
    let(:hecks) { boot_hecks_in_memory.registry.bluebook("Hecks") }
    let(:workspace) { hecks.aggregates.find { |aggregate| aggregate.name == "Workspace" } }

    it "has no Revision, LinkedTree or Landing of its own" do
      expect(hecks.aggregates.map(&:name)).not_to include("Revision", "LinkedTree", "Landing")
    end

    it "keeps only the questions about this copy of Hecks on its Workspace" do
      expect(workspace.queries.map(&:name)).to contain_exactly("Settings", "Doctor", "Where")
    end

    it "gives its Workspace no port but the ones those questions ask" do
      expect(workspace.ports.map(&:name)).to contain_exactly("Settings", "Doctor", "Where")
    end
  end
end
