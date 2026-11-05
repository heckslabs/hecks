require "spec_helper"

# The orchestrator's routing as events: a Work item with no conflict is routed by rule and no advice
# is asked; a conflicting one asks for advice; a check past the hop limit is refused. The event log
# shows which policy fired, so the rule is seen, not assumed.
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

  def check(conflict, hops: 1)
    routing.check!(work: { value: "w1" }, conflict: { value: conflict }, hops: { value: hops })
  end

  def fired
    @dispatcher.events.map { |event| event.respond_to?(:name) ? event.name : event[:name] }.map(&:to_s)
  end

  it "routes a Work item with no conflict by rule", :aggregate_failures do
    check("no")
    expect(fired).to include(a_string_ending_with("WorkRouted"))
    expect(fired).not_to include(a_string_ending_with("DispatchAdviceRequested"))
  end

  it "asks for advice on a Work item that conflicts", :aggregate_failures do
    check("yes")
    expect(fired).to include(a_string_ending_with("DispatchAdviceRequested"))
    expect(fired).not_to include(a_string_ending_with("WorkRouted"))
  end

  it "refuses a check at the hop limit, by name" do
    expect { check("yes", hops: 3) }.to raise_error(Hecks::Runtime::GivenNotMet, /under the hop limit/)
  end
end
