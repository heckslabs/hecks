require "spec_helper"

# The orchestrator's routing as events: the check is handed the areas a Work item spans and the
# started items it overlaps, and the bluebook's rule decides. One area and no overlap is routed by
# rule and no advice is asked; several areas, or any overlap, asks for advice; a check past the hop
# limit is refused. The event log shows which policy fired, so the rule is seen, not assumed.
RSpec.describe "the Agents orchestrator routing" do
  def agents_root = File.join(InMemoryDomain::ROOT, "lib/hecks/agents")

  def boot_agents
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER, File.join(agents_root, "agents.bluebook")].each { |file| Kernel.load(file) }
    end
    @dispatcher = Hecks::Runtime::Dispatcher.new(registry)
    Hecks::Runtime::Loader.bind_runtime(@dispatcher)
  end

  before { boot_agents }

  let(:routing) { Hecks::Agents::Routing }

  def check(areas: 1, overlaps: 0, hops: 1)
    routing.check!(work: { value: "w1" }, areas: { value: areas }, overlaps: { value: overlaps },
                   hops: { value: hops }, advice: { value: "a-w1" })
  end

  def fired
    @dispatcher.events.map { |event| event.respond_to?(:name) ? event.name : event[:name] }.map(&:to_s)
  end

  it "routes a Work item in one area that overlaps nothing by rule", :aggregate_failures do
    check
    expect(fired).to include(a_string_ending_with("WorkRouted"))
    expect(fired).not_to include(a_string_ending_with("DispatchAdviceRequested"))
  end

  it "asks for advice on a Work item that spans several areas", :aggregate_failures do
    check(areas: 2)
    expect(fired).to include(a_string_ending_with("DispatchAdviceRequested"))
    expect(fired).not_to include(a_string_ending_with("WorkRouted"))
  end

  it "asks for advice on a Work item that overlaps a started one", :aggregate_failures do
    check(overlaps: 1)
    expect(fired).to include(a_string_ending_with("DispatchAdviceRequested"))
    expect(fired).not_to include(a_string_ending_with("WorkRouted"))
  end

  it "records the conflict the rule found on the routing" do
    check(overlaps: 1)
    expect(routing.find("w1").conflict.value).to eq("yes")
  end

  it "refuses a check at the hop limit, by name" do
    expect { check(areas: 2, hops: 3) }.to raise_error(Hecks::Runtime::GivenNotMet, /under the hop limit/)
  end
end
