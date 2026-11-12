require "spec_helper"

# The goal of the epic a Work item belongs to rides in its brief, so a coder knows its purpose.
RSpec.describe "the Coder brief's epic" do
  let(:coder_root) { File.join(InMemoryDomain::ROOT, "lib/hecks/coder") }
  let(:epic) do
    { epic_title: { value: "Retire routes" }, epic_outcome: { value: "No route reads a stale table" },
      epic_tier: { value: 2 }, epic_decision: { value: "0136" } }
  end

  let(:runtime) do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER].each { |file| Kernel.load(file) }
      %w[coder.bluebook coder.hecksagon].each { |file| Kernel.load(File.join(coder_root, file)) }
    end
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def compose(**extra)
    runtime
    Coder::Brief.compose!(work: { value: "work/x" }, outcome: { value: "Retire the old route" }, **extra)
  end

  def epic_of(brief) = %i[epic_title epic_outcome epic_tier epic_decision].to_h { |name| [name, brief[name]&.[](:value)] }

  it "carries the epic's title, outcome, tier and decision" do
    expect(epic_of(compose(**epic))).to eq(epic.transform_values { |field| field[:value] })
  end

  it "carries no epic when the work item has none" do
    expect(epic_of(compose).values.compact).to be_empty
  end
end
