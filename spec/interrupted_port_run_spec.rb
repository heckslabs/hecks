require "spec_helper"

# A run whose outbound port is interrupted mid-answer ends refused, naming the operation it stopped
# in, so the run is recorded rather than left open. The DomainRuntime port's Check ask is outbound
# and declares refuses.
RSpec.describe "an interrupted port run" do
  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  def interrupted_check
    adapter = Object.new
    def adapter.check(**) = raise(Interrupt)
    allow(Hecks::Runtime::AdapterLookup).to receive(:call).and_return(adapter)
    dispatcher = Hecks::Runtime::Dispatcher.new(@hecks.registry)
    dispatcher.dispatch_flat("Hecks::ModelCheckRun.ModelCheck", run: { value: "C1" })
    @hecks.registry.event_log.to_a.map { |event| event.to_h.to_s }.join("\n")
  end

  it "records the refusal naming the operation the run stopped in", :aggregate_failures do
    log = interrupted_check

    expect(log).to include("ModelCheckRefused")
    expect(log).to include("interrupted during Check")
  end

  it "answers an interrupted line as refused and names the command it stopped in", :aggregate_failures do
    allow(Hecks::Adapters::Driving::CliRunner).to receive(:dispatch).and_raise(Interrupt)
    runtime = Hecks::Runtime::Dispatcher.new(@hecks.registry)

    text, status = Hecks::Adapters::Driving::CliRunner.call(runtime: runtime, argv: ["ModelCheckRun.model_check!", "run=C2"])

    expect(status).to eq(Hecks::Adapters::Driving::ExitStatus::REFUSED)
    expect(text).to include("interrupted during ModelCheckRun.model_check")
  end
end
