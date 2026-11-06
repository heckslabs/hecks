require "spec_helper"

# The architect's plan review as events: a request under the hop limit is accepted, one past it
# is refused by name, and only a known verdict is recorded. Booted in Memory, one registry per run.
RSpec.describe "the Agents plan review" do
  def agents_root = File.join(InMemoryDomain::ROOT, "lib/hecks/agents")

  def boot_agents
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER, File.join(agents_root, "agents.bluebook")].each { |file| Kernel.load(file) }
    end
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:review) { Hecks::Agents::PlanReview }

  before { boot_agents }

  def request(hops)
    review.request!(work: { value: "w1" }, hops: { value: hops }, role: { value: "architect" },
                    repo: { value: "/tmp" }, plan: { value: "a plan" })
  end

  it "accepts a request under the hop limit" do
    expect { request(2) }.not_to raise_error
  end

  it "refuses a request at the hop limit, by name" do
    expect { request(3) }.to raise_error(Hecks::Runtime::GivenNotMet, /under the hop limit/)
  end

  it "records a verdict the architect gives" do
    expect { request(1).answer!(verdict: { value: "sound" }) }.not_to raise_error
  end

  it "refuses a verdict the architect does not give, by name" do
    expect { request(1).answer!(verdict: { value: "maybe" }) }
      .to raise_error(Hecks::Runtime::GivenNotMet, /verdict is one the architect gives/)
  end
end
