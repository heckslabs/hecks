# What the plan review time limit specs drive: the Agents bluebook booted alone in Memory, and
# reviews asked for, lapsed and unstarted with the clock given by hand.
module PlanReviewLimitHelpers
  def agents_root = File.join(InMemoryDomain::ROOT, "lib/hecks/agents")

  def boot_agents
    registry = @agents_registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER, File.join(agents_root, "agents.bluebook")].each { |file| Kernel.load(file) }
    end
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def review = Hecks::Agents::PlanReview

  # A review asked for the second time by default, the one a lapse ends;
  # `asks: { value: 0 }` is the first.
  def request(run: "r1", at: 1000, plan: { value: "a plan that is long enough" }, asks: { value: 1 }, **more)
    review.request!(run: { value: run }, work: { value: "w1" }, hops: { value: 1 }, role: { value: "architect" },
                    repo: { value: "/tmp" }, plan: plan, now: { value: at }, asks: asks, **more)
  end

  def lapse(asked, at:)
    asked.lapse!(work: { value: "w1" }, reason: { value: "no verdict came" }, now: { value: at })
  end

  def unstart(asked) = asked.unstart!(work: { value: "w1" }, reason: { value: "declined" }, now: { value: 1001 })

  def open_runs = review.open.map { |row| row.to_h.transform_keys(&:to_s)["run"].value }

  OVERDUE_ITEM = { "kind" => "verdict_overdue", "owner_run" => "w1" }.freeze

  # The `Turn.finish!` a lapsed review's reason tells the blocked coder to run.
  def finish_blocked_turn
    Hecks::Agents::Turn.finish!(run: { value: "w1" }, role: { value: "coder" }, at: { value: "2026-11-18T12:00Z" },
                                verdict: { value: "blocked" },
                                stuck: [OVERDUE_ITEM.merge("what" => "no verdict", "since" => "-", "link" => "-")])
  end

  # One of PlanReview's `Setting` rows, by name, as the booted bluebook declares it.
  def setting(name)
    reviews = @agents_registry.bluebook("Agents").aggregate("PlanReview")
    reviews.value_objects.find { |object| object.hecks_name == "Setting" }.members.find { |row| row[:name] == name }
  end

  # The events the booted registry recorded under one bare name, oldest first.
  def events_named(name) = @agents_registry.event_log.select { |event| event.name == name }

  def reask(asked, at:)
    asked.reask!(work: { value: "w1" }, hops: { value: 1 }, role: { value: "architect" }, repo: { value: "/tmp" },
                 plan: { value: "a plan that is long enough" }, now: { value: at })
  end
end
