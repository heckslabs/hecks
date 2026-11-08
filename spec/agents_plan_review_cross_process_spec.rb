require "spec_helper"

# The architect's verdict is recorded whether or not the process that hears it holds the request:
# Hecks runs in Memory per process, so a verdict must not depend on the request row. `Record`
# creates the review from the verdict, and takes the place of a request that is still waiting.
RSpec.describe "the Agents plan review across processes" do
  def boot_agents
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER, File.join(InMemoryDomain::ROOT, "lib/hecks/agents/agents.bluebook")]
        .each { |file| Kernel.load(file) }
    end
    @dispatcher = Hecks::Runtime::Dispatcher.new(registry)
    Hecks::Runtime::Loader.bind_runtime(@dispatcher)
  end

  def request
    @dispatcher.dispatch_flat("Agents::PlanReview.Request", run: { value: "r1" }, work: { value: "w1" },
                                                            hops: { value: 1 }, role: { value: "architect" },
                                                            repo: { value: "/tmp" }, plan: { value: "p" })
  end

  def record
    @dispatcher.dispatch_flat("Agents::PlanReview.Record", run: { value: "r1" }, work: { value: "w1" },
                                                           verdict: { value: "sound" }, findings: { value: "none" })
  end

  def reviews = @dispatcher.registry.repository("Agents", @dispatcher.registry.bluebook("Agents").aggregate("PlanReview")).all

  it "records the verdict in a process that never saw the request" do
    boot_agents
    expect(record.instance.verdict.value).to eq("sound")
  end

  it "records the verdict over a request still waiting in the same process", :aggregate_failures do
    boot_agents
    request
    record
    expect(reviews.map { |row| row.id.to_s }.sort).to eq(%w[r1 r1~1])
    expect(reviews.find { |row| row.id.to_s == "r1" }.verdict.value).to eq("sound")
  end
end
