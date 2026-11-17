require "spec_helper"

# An architect's verdict for a run no request row names is recorded as a review of its own, so the
# verdict is a fact on the change and not a lookup. Booted in Memory, one registry per run.
RSpec.describe "the Agents plan review of an unasked run" do
  let(:root) { File.join(InMemoryDomain::ROOT, "lib/hecks/agents") }
  let(:verdict_given) { /verdict is one the architect gives/ }

  before do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER, File.join(root, "agents.bluebook")].each { |file| Kernel.load(file) }
    end
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def record(verdict)
    Hecks::Agents::PlanReview.record!(run: { value: "orphan" }, work: { value: "w1" }, verdict: { value: verdict },
                                      findings: { value: "six changes" })
  end

  it "records the verdict with no request row" do
    expect(record("changes").verdict.value).to eq("changes")
  end

  it "keeps the findings with the verdict" do
    expect(record("sound").findings.value).to eq("six changes")
  end

  it "refuses a verdict the architect does not give, by name" do
    expect { record("maybe") }.to raise_error(Hecks::Runtime::GivenNotMet, verdict_given)
  end
end
