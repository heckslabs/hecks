# The Agents bluebook booted in Memory for the review miss spec: clean and real_bug reviews of a
# work item's commits, and Deliver's `RedEpisode.EpisodeReverting` reacted to as the event pump
# would. Each example boots its own registry, so no state is shared.
module ReviewMissHelpers
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

  # A review of `commit` on work item `work`, scoped to the Agents domain and judged clean on the
  # evidence of one passing behaviors run.
  #
  # @return [Object] the judged review
  def clean(commit, work, tier: "full")
    review = request(commit, work)
    review.scope!(tier: value(tier), domains: value("|lib/hecks/agents|"), bluebooks: value("||"))
    review.count!(kind: value("behaviors"), run: value("#{commit}-behaviors"), subject: value("lib/hecks/agents"),
                  status: value("succeeded"), scenarios: value(4))
    review.judge!(judgment: value("clean"))
  end

  # @return [Object] a review of `commit` on `work` judged real_bug
  def real_bug(commit, work)
    request(commit, work).judge!(judgment: value("real_bug"), findings: value("spec/a_spec.rb:3 fails"))
  end

  # @return [Object] a requested review of `commit` on `work`
  def request(commit, work)
    Hecks::Agents::SubmissionReview
      .request!(submission: value(commit), work: value(work), hops: value(1), role: value("reviewer"),
                repo: value("/tmp/#{work}"), brief: value(work))
  end

  # Reacts to `RedEpisode.EpisodeReverting` for `work`, as Deliver emits it.
  #
  # @return [Array<Hash>] one record per policy that heard it
  def revert(episode, work)
    event = Hecks::Runtime::Event.new(name: "EpisodeReverting", aggregate: "Hecks::RedEpisode", id: episode,
                                      payload: episode_facts(episode, work), occurred_at: Hecks::Runtime::Event.stamp)
    Hecks::Runtime::PolicyInterpreter.new(@registry, dispatcher: @dispatcher).react(event, "Agents")
  end

  # @return [Hash{Symbol => Hash}] the facts a reverting episode carries
  def episode_facts(episode, work)
    { run: value(episode), base: value("b0"), culprit: value("m-#{episode}"), branch: value(work),
      spec: value("spec/a_spec.rb"), example: value("spec/a_spec.rb:3"), work: value(work),
      finding: value("culprit m-#{episode}") }
  end

  def misses = Hecks::Agents::ReviewMiss.all

  def miss(commit) = Hecks::Agents::ReviewMiss.find(commit)

  def missed_commits = misses.map { |record| record.submission.value }.sort
end
