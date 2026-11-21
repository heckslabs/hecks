require "spec_helper"

# A planned Work item is briefed by the Coder module: the brief is composed from its title,
# detail and area, and a row with no area gets a brief with none.
RSpec.describe "the brief of a planned Work item" do
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

  def plan(key, **extra)
    runtime
    Tickets::Work.plan!(work: { value: key }, title: { value: "Retire #{key}" },
                        detail: { value: "Map it first" }, **extra)
  end

  def brief_for(key) = Coder::Brief.for(work: { value: key }).first

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

  it "gives a red train's brief the bisect first, with the two ways to satisfy it", :aggregate_failures do
    plan("red-train-55")
    bisect = brief_for("red-train-55")[:bisect][:value]
    expect(bisect).to start_with("BISECT FIRST").and include("Integration.probe!", "BisectLog.log!", "obvious")
    expect(bisect).to include("work_key={work}", "Landing.land! is refused")
  end

  it "gives a red main's brief the bisect too, and any other brief none" do
    plan("red-main-1")
    plan("brief/c")
    bisects = %w[red-main-1 brief/c].map { |key| brief_for(key)[:bisect]&.[](:value).to_s }
    expect(bisects).to match([/BISECT FIRST/, ""])
  end
end
