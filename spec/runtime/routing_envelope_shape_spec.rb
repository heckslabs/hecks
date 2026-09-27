require "spec_helper"

# `Routing.envelope` must refuse a non-String, non-Hash `to:` as TypeMismatch, matching Rust's
# `RoutingEnvelope::from_json`. Only a domain with a command attribute named `to` reaches it,
# because flat kwargs dispatch binds that key to the routing `to:` before the payload is built.
RSpec.describe "Routing.envelope's non-Hash branch" do
  ROSTER_BLUEBOOK_DIR = File.join(InMemoryDomain::ROOT, "examples/roster/bluebook").freeze

  def boot_roster
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      InMemoryDomain.load_bluebook_files(ROSTER_BLUEBOOK_DIR)
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end
  end

  let(:runtime) { boot_roster }

  before { runtime.dispatch_flat("Roster::Roster.Open", name: { value: "juliet india hotel" }) }

  it "refuses a non-string, non-Hash scalar as TypeMismatch, not as an absent domain argument" do
    # Fuzz seed 1 / step 9: a corrupted out-of-i64-range Integer for `Mark`'s own `to`,
    # dispatched as flat kwargs so it lands in the routing parameter.
    expect do
      runtime.dispatch_flat("Roster::Roster.Mark",
                            to:   -1_267_650_600_228_229_401_496_703_205_376,
                            name: "juliet india hotel")
    end.to raise_error(Hecks::Runtime::TypeMismatch, /to: must be a string aggregate identity or an entity route/)
  end

  it "still accepts a real string identity for the routing envelope" do
    expect do
      runtime.dispatch("Roster::Roster.Mark", to: "juliet india hotel", with: { to: { value: 5 } })
    end.not_to raise_error
  end

  it "still refuses an unrecognized Hash-shaped envelope key exactly as before" do
    expect do
      runtime.dispatch_flat("Roster::Roster.Mark", to: { value: 0 }, name: "juliet india hotel")
    end.to raise_error(Hecks::Runtime::TypeMismatch, "to: does not recognize value")
  end
end
