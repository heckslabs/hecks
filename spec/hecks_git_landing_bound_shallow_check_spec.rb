require "spec_helper"
require "hecks/hecks/adapters/delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_landing")

# The shallow check a landing runs: the adapter the booted project bound to the ShallowChecks port,
# or nothing when it binds none.
RSpec.describe Hecks::Adapters::GitLanding::BoundShallowCheck do
  # A registry that binds no adapter to any port.
  def unbound = Struct.new(:adapters).new({})

  # What the check was asked, by a stand-in for the adapter Hecks binds.
  def asked_of(registry)
    seen = []
    stand_in = Struct.new(:seen) { def shallow_check(**held) = seen << held }.new(seen)
    Hecks::Runtime::AdapterLookup.standing_in(->(_port, _asked) { stand_in }) do
      described_class.new(registry).call("/tree", "work/a", "main")
    end
    seen
  end

  it "asks the adapter Hecks binds, with the worktree, the branch and where it lands" do
    registry = boot_hecks_in_memory.registry
    expect(asked_of(registry)).to eq([{ checkout: "/tree", branch: "work/a", onto: "main" }])
  end

  it "runs nothing, and refuses nothing, for a project that binds no shallow check" do
    expect(described_class.new(unbound).call("/tree", "work/a", "main")).to be_nil
  end

  it "binds exactly one adapter to the port in Hecks" do
    bound = boot_hecks_in_memory.registry.adapters.values.select { |adapter| adapter.port == described_class::PORT }
    expect(bound.map(&:name)).to eq(["GitShallowCheck"])
  end
end
