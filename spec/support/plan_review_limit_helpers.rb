# What the plan review time limit specs drive: the Agents bluebook booted alone in Memory, and
# reviews asked for, lapsed and unstarted with the clock given by hand.
module PlanReviewLimitHelpers
  def agents_root = File.join(InMemoryDomain::ROOT, "lib/hecks/agents")

  def boot_agents
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER, File.join(agents_root, "agents.bluebook")].each { |file| Kernel.load(file) }
    end
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def review = Hecks::Agents::PlanReview

  def request(run: "r1", at: 1000, **more)
    review.request!(run: { value: run }, work: { value: "w1" }, hops: { value: 1 }, role: { value: "architect" },
                    repo: { value: "/tmp" }, plan: { value: "a plan" }, now: { value: at }, **more)
  end

  def lapse(asked, at:)
    asked.lapse!(work: { value: "w1" }, reason: { value: "no verdict came" }, now: { value: at })
  end

  def unstart(asked) = asked.unstart!(work: { value: "w1" }, reason: { value: "declined" }, now: { value: 1001 })

  def open_runs = review.open.map { |row| row.to_h.transform_keys(&:to_s)["run"].value }
end
