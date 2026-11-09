require "spec_helper"
require_relative "../lib/hecks/hecks/adapters/in_process_boot"

# A coder waits for its architect's verdict with `Operation.follow`, named by event. Booted in
# Memory, so the follow reads the log of a real Agents registry and not a stand-in.
RSpec.describe "following the Agents plan review events" do
  let(:root) { File.join(InMemoryDomain::ROOT, "lib/hecks/agents") }
  let(:adapter) { Hecks::Adapters::InProcessBoot.new }
  let(:registry) { Hecks::Runtime::Registry.new }

  before do
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER, File.join(root, "agents.bluebook")].each { |file| Kernel.load(file) }
    end
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def record(run)
    Hecks::Agents::PlanReview.record!(run: { value: run }, work: { value: "w1" }, verdict: { value: "sound" },
                                      findings: { value: "none" })
  end

  def followed(**options)
    names = []
    adapter.stream(domain: root, registry: registry, aggregate: "PlanReview", timeout: 0, **options) do |entry|
      names << entry["name"]
    end
    names
  end

  it "sees the events of a recorded verdict", :aggregate_failures do
    record("mine")

    expect(followed).to include("PlanReviewRecorded")
    expect(followed(names: "PlanReviewRecorded")).to all(eq("PlanReviewRecorded"))
  end

  it "hands over nothing for a name no recorded event has" do
    record("mine")

    expect(followed(names: "PlanReviewRequested")).to be_empty
  end

  it "picks up a verdict recorded after the cursor, not before it" do
    record("earlier")
    cursor = adapter.stream(domain: root, registry: registry, aggregate: "PlanReview", from_now: true, timeout: 0) { nil }
    record("later")

    expect(followed(since: cursor, names: "PlanReviewRecorded").size).to eq(1)
  end
end
