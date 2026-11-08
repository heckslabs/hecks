require "spec_helper"

# A review requested in one process is answered in another that never saw the request: Hecks runs
# in Memory per process, so the verdict must not depend on the request row. One registry per process.
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

  def request_in_one_process
    boot_agents
    Hecks::Agents::PlanReview.request!(run: { value: "r1" }, work: { value: "w1" }, hops: { value: 1 },
                                       role: { value: "architect" }, repo: { value: "/tmp" }, plan: { value: "p" })
  end

  def answer_in_another_process
    boot_agents
    facts = { verdict: { value: "sound" }, findings: { value: "none" } }
    @dispatcher.dispatch("Agents::PlanReview.Answer", to: "r1", with: facts)
  end

  it "records the verdict in a process that never saw the request" do
    request_in_one_process
    expect(answer_in_another_process.instance.verdict.value).to eq("sound")
  end
end
