require "spec_helper"

# The brief a coder session reads: the Work row's outcome, the area it may edit, and the standing
# rules the Coder bluebook carries once. Each example boots its own Hecks domain.
RSpec.describe "the Coder brief" do
  let(:coder_root) { File.join(InMemoryDomain::ROOT, "lib/hecks/coder") }

  let(:runtime) do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER].each { |file| Kernel.load(file) }
      Kernel.load(File.join(coder_root, "coder.bluebook"))
      Kernel.load(File.join(coder_root, "coder.hecksagon"))
    end
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def compose(**extra)
    runtime
    Coder::Brief.compose!(work: { value: "work/x" }, outcome: { value: "Retire the old route" },
                          detail: { value: "Map the graph first" }, **extra)
  end

  it "takes the outcome and detail from the row" do
    brief = compose

    expect([brief[:outcome][:value], brief[:detail][:value]]).to eq(["Retire the old route", "Map the graph first"])
  end

  it "carries the area and the stop conditions when the row names an area", :aggregate_failures do
    brief = compose(area: ["lib/hecks/coder"])

    expect(brief[:area].to_s).to include("lib/hecks/coder")
    expect(brief[:rules][:value]).to include("risk of losing data", "owner alone", "outside the area")
  end

  it "omits the area when the row has none, without error", :aggregate_failures do
    brief = compose

    expect(brief[:area]).to be_nil.or be_empty
    expect(brief[:rules][:value]).to include("Map the whole picture")
  end

  it "carries the verification rules" do
    expect(compose[:verification][:value]).to include("launcher", "quick gate", "Do not run the full suite")
  end
end
