require "spec_helper"

# A reviewer's finding goes to a coder by its route, counted against the hop limit, and a route at
# the limit is exhausted instead. Booted in Memory, one registry per example.
RSpec.describe "the Agents finding route" do
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

  def events_named(name)
    @dispatcher.events.select { |event| (event.respond_to?(:name) ? event.name : event[:name]).to_s.end_with?(name) }
  end

  def judge(commit, judgment, findings = "spec/a_spec.rb:3 expects the old word")
    Hecks::Agents::SubmissionReview
      .request!(submission: { value: commit }, work: { value: "w1" }, hops: { value: 1 },
                role: { value: "reviewer" }, repo: { value: "/tmp/w1" }, brief: { value: "w1" })
      .judge!(judgment: { value: judgment }, findings: { value: findings })
  end

  def route = Hecks::Agents::FindingRoute.find("w1")

  def brief_of(event) = event.payload[:brief][:value].to_s

  before { boot_agents }

  it "sends a work item's first finding to a coder once" do
    judge("c1", "real_bug")
    expect(events_named("FindingRouted").size).to eq(1)
  end

  it "counts each finding of the work item as one round" do
    %w[c1 c2].each { |commit| judge(commit, "real_bug") }
    expect(route.rounds.value).to eq(2)
  end

  it "briefs a stale expectation to edit only the stale spec" do
    judge("c1", "stale_expectation")
    expect(brief_of(events_named("FindingRouted").last)).to include("Edit only that spec")
  end

  it "briefs a missing behavior with the one step, write the behavior" do
    judge("c1", "missing_behavior", "lib/hecks/agents: a route at the limit is exhausted")
    expect(brief_of(events_named("FindingRouted").last)).to include("Your one step: write the behavior")
  end

  it "exhausts the route at the hop limit and starts no coder", :aggregate_failures do
    %w[c1 c2 c3 c4].each { |commit| judge(commit, "real_bug") }
    expect(events_named("FindingRouted").size).to eq(3)
    expect(events_named("FindingsExhausted").size).to eq(1)
  end

  it "routes nothing for a landed branch" do
    judge("c1", "landed")
    expect(events_named("FindingRouted")).to be_empty
  end
end
