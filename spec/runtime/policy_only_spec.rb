require "spec_helper"

# `policy_only` and `acts_as` at dispatch (ADR 0216): a command only a policy's reaction may
# dispatch, the role that reaction dispatches it as, and what a dispatch with no caller is.
RSpec.describe "a policy_only command and an acts_as reaction" do
  FIXTURE = File.join(InMemoryDomain::ROOT, "spec/fixtures/role_unstated_caller.bluebook")

  def build
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      Kernel.load(FIXTURE)
      Kernel.load(File.expand_path("../../lib/hecks/ports/authorization.port", __dir__))
      Kernel.load(File.expand_path("../../lib/hecks/adapters/driven/governance_authorization.adapter", __dir__))
      bind_hecksagons
    end
    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def bind_hecksagons
    Hecks.hecksagon("RoleUnstatedCaller") do
      attaches "Governance"
      RoleUnstatedCaller::Plant.persisted_by("Memory")
    end
    sibling_governance!
  end

  def wilted(runtime)
    Hecks.as_caller(role: "Gardener") { runtime.dispatch_flat("RoleUnstatedCaller::Plant.Wilt", tag: { value: "fern" }) }
  end

  def water(runtime) = runtime.dispatch_flat("RoleUnstatedCaller::Plant.Water", plant: "fern")

  def watered?(runtime) = runtime.events.map(&:name).include?("PlantWatered")

  def refused_by_hand = "Water refused — only a policy reaction may dispatch it, and a caller did"

  it "runs the reaction a stated caller set off as the role its policy acts as" do
    runtime = build
    wilted(runtime)
    expect(watered?(runtime)).to be(true)
  end

  it "refuses a caller who states the command's own role, since only a reaction may dispatch it" do
    runtime = build
    wilted(runtime)
    expect { Hecks.as_caller(role: "System") { water(runtime) } }.to raise_error(Hecks::Runtime::Unauthorized, refused_by_hand)
  end

  it "refuses the caller who states no role, in the same words" do
    runtime = build
    wilted(runtime)
    expect { Hecks::Runtime::Caller.unstated { water(runtime) } }.to raise_error(Hecks::Runtime::Unauthorized, refused_by_hand)
  end

  it "admits a dispatch with no caller bound, the process acting for itself" do
    runtime = build
    runtime.dispatch_flat("RoleUnstatedCaller::Plant.Wilt", tag: { value: "fern" })
    expect { water(runtime) }.not_to raise_error
  end

  describe Hecks::Runtime::Caller do
    def reaction_origin = described_class.without(reacting: true) { described_class.origin }

    def origin_inside_process_block = described_class.as(role: "Maintainer") { described_class.without { reaction_origin } }

    it "keeps the caller a cascade began under as the origin of its reactions" do
      expect(described_class.as(role: "Maintainer") { reaction_origin }.role).to eq("Maintainer")
    end

    it "begins a cascade under no caller inside a block the process runs for itself" do
      expect(origin_inside_process_block).to be_nil
    end

    def undeclared_reaction_role = described_class.without(reacting: true) { reaction_role }

    def reaction_role = described_class.reacting_as(nil, enforcing: true) { described_class.current&.role }

    it "binds an undeclared reaction as the unstated caller in a cascade a caller began" do
      expect(described_class.as(role: "Maintainer") { undeclared_reaction_role }).to eq("Anonymous")
    end

    it "leaves an undeclared reaction unbound in a cascade begun with no caller" do
      expect(undeclared_reaction_role).to be_nil
    end
  end
end
