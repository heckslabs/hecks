# The Agents bluebook booted in Memory for the canary spec: known-bad patches added, the cadence
# ticked as a sweep would, and plants reviewed and judged. Each example boots its own registry.
module CanaryHelpers
  # A day, the cadence's default window.
  DAY = 86_400

  def agents_root = File.join(InMemoryDomain::ROOT, "lib/hecks/agents")

  # Loads the Agents bluebook into a fresh registry and binds its runtime.
  #
  # @return [Hecks::Runtime::Dispatcher] the dispatcher the bluebook's commands run through
  def boot_agents
    @registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(@registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER, File.join(agents_root, "agents.bluebook")].each { |file| Kernel.load(file) }
    end
    @dispatcher = Hecks::Runtime::Dispatcher.new(@registry)
    Hecks::Runtime::Loader.bind_runtime(@dispatcher)
  end

  def value(text) = { value: text }

  # Keeps a known-bad patch whose review must give `real_bug`.
  #
  # @return [Object] the canary
  def add_canary(name)
    Hecks::Agents::Canary.add!(canary: value(name), base: value("main"), patch: value("diff --git a/x b/x"),
                               finding: value("real_bug"), branch: value("tidy-#{name}"),
                               message: value("Tidy #{name}"))
  end

  # Ticks the cadence at `now`, as a sweep does; a tick inside the window is refused.
  def tick(now)
    Hecks::Agents::CanaryCadence.find("canary").tick!(now: value(now))
  rescue Hecks::Refused
    nil
  end

  # Opens a plant of `canary` on commit `commit`, as a cut scratch branch does.
  #
  # @return [Object] the plant
  def plant(commit, canary)
    Hecks::Agents::CanaryPlant.open!(submission: value(commit), canary: value(canary), checkout: value("/tmp/#{commit}"),
                                     branch: value("tidy-#{canary}-1"), expected: value("real_bug"))
  end

  # Scopes and judges the review of `commit` on the evidence of one passing behaviors run.
  def judge(commit, judgment, tier: "full")
    review = Hecks::Agents::SubmissionReview.find(commit)
    review.scope!(tier: value(tier), domains: value("|lib/hecks/agents|"), bluebooks: value("||"))
    review.count!(kind: value("behaviors"), run: value("#{commit}-behaviors"), subject: value("lib/hecks/agents"),
                  status: value("succeeded"), scenarios: value(4))
    review.judge!(judgment: value(judgment), findings: value("spec/a_spec.rb:3 fails"))
  end

  # @return [Hash] the cadence's named Setting row
  def cadence_setting(name)
    cadence = @registry.bluebook("Agents").aggregate("CanaryCadence")
    cadence.value_objects.find { |object| object.hecks_name == "Setting" }.members.find { |row| row[:name] == name }
  end

  def canary(name) = Hecks::Agents::Canary.find(name)

  def outcome(commit) = Hecks::Agents::CanaryPlant.find(commit).outcome&.value.to_s

  # @return [Object] what the dispatcher answers for the CanaryCatchesByTier read model
  def catches_by_tier = @dispatcher.query("Agents.CanaryCatchesByTier")
end
