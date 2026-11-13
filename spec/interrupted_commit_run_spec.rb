require "spec_helper"

# A Commit run whose git port is interrupted mid-answer ends refused, naming the operation it
# stopped in, so the run is recorded rather than left open. The Commit port is outbound and
# declares refuses.
RSpec.describe "an interrupted Commit run" do
  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  def interrupted_commit
    adapter = Object.new
    def adapter.commit(**) = raise(Interrupt)
    allow(Hecks::Runtime::AdapterLookup).to receive(:call).and_return(adapter)
    dispatcher = Hecks::Runtime::Dispatcher.new(@hecks.registry)
    dispatcher.dispatch_flat("Delivery::Revision.Make",
                             run: { value: "C1" }, checkout: { value: "/tmp/x" }, message: { value: "m" })
    @hecks.registry.event_log.to_a.map { |event| event.to_h.to_s }.join("\n")
  end

  it "records the refusal naming the operation the run stopped in", :aggregate_failures do
    log = interrupted_commit

    expect(log).to include("CommitRefused")
    expect(log).to include("interrupted during Commit")
  end

  it "answers an interrupted line as refused and names the command it stopped in", :aggregate_failures do
    allow(Hecks::Adapters::Driving::CliRunner).to receive(:dispatch).and_raise(Interrupt)
    runtime = Hecks::Runtime::Dispatcher.new(@hecks.registry)

    text, status = Hecks::Adapters::Driving::CliRunner.call(runtime: runtime, argv: ["Workspace.status"])

    expect(status).to eq(Hecks::Adapters::Driving::ExitStatus::REFUSED)
    expect(text).to include("interrupted during Workspace.status")
  end
end
