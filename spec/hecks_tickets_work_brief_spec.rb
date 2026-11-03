require "spec_helper"

# A planned Work row is briefed by the Coder module: the brief is composed from the row's title,
# detail and area, and a row with no area gets a brief with none.
RSpec.describe "the brief of a planned Work row" do
  let(:root) { InMemoryDomain::ROOT }

  let(:runtime) do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER].each { |file| Kernel.load(file) }
      Kernel.load(File.join(root, "lib/hecks/coder/coder.bluebook"))
      Kernel.load(File.join(root, "lib/hecks/coder/coder.hecksagon"))
      Kernel.load(File.join(root, "lib/hecks/tickets/bluebook/tickets.bluebook"))
      Kernel.load(File.join(root, "lib/hecks/tickets/bluebook/tickets.hecksagon"))
    end
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  # Plans a row under a decision accepted in this runtime's own Memory store.
  def plan(key, **extra)
    runtime.dispatch_flat("Tickets::Adr.Draft", adr: "0001", title: "Brief the work")
    runtime.dispatch_flat("Tickets::Adr.Accept", adr: "0001")
    Tickets::Work.plan!(work: { value: key }, title: { value: "Retire #{key}" },
                        detail: { value: "Map it first" }, decision: "0001", **extra)
  end

  def brief_for(key) = Coder::Brief.for(row: { value: key }).first

  it "composes the brief from the row's title, detail and area", :aggregate_failures do
    plan("brief/a", area: [{ value: "lib/hecks/coder" }])
    brief = brief_for("brief/a")

    expect(brief[:outcome][:value]).to eq("Retire brief/a")
    expect(brief[:detail][:value]).to eq("Map it first")
    expect(brief[:area].to_s).to include("lib/hecks/coder")
  end

  it "composes a brief with no area for a row that names none", :aggregate_failures do
    plan("brief/b")
    brief = brief_for("brief/b")

    expect(brief[:area]).to be_nil.or be_empty
    expect(brief[:rules][:value]).to include("Map the whole picture")
  end
end
