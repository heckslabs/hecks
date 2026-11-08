require "spec_helper"

# The architect's verdict is recorded whether or not the process that hears it holds the request:
# Hecks runs in Memory per process, so a verdict must not depend on the request row. `Record`
# creates the review from the verdict when the request is unknown; `Answer` is the route where
# the request is held. Together the two policies on the job read cover either process.
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

  it "records the verdict in a process that never saw the request" do
    boot_agents
    expect(record.instance.verdict.value).to eq("sound")
  end

  it "refuses answering a request this process never saw, by name" do
    boot_agents
    expect { @dispatcher.dispatch("Agents::PlanReview.Answer", to: "r1", with: { verdict: { value: "sound" } }) }
      .to raise_error(Hecks::Runtime::NotFound, /no PlanReview/)
  end

  it "refuses recording over a request this process holds, so Answer is the route there" do
    boot_agents
    request
    expect { record }.to raise_error(Hecks::Runtime::AlreadyExists)
  end
end
