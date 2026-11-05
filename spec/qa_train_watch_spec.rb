require "spec_helper"
require "hecks/quality_control/cli/qa_train_watch"

# The QA tick's train watch: every queued boarding is asked for its pull request's state, and a
# boarding that cannot be asked is counted and reported, not skipped.
RSpec.describe Hecks::QualityControlCli::QaTrainWatch do
  let(:runtime) { instance_double(Hecks::Runtime::Dispatcher, query: queued, dispatch_flat: nil) }
  let(:queued) { [] }

  before { allow(Hecks).to receive(:boot).and_return(runtime) }

  def run_watch = described_class.call([], root: "/repo")

  it "answers success with nothing to watch when no boarding is queued", :aggregate_failures do
    expect(run_watch).to eq(0)
    expect(runtime).not_to have_received(:dispatch_flat)
  end

  it "asks each queued boarding by its run key", :aggregate_failures do
    queued.replace([{ run: { value: "push-1" } }, { run: { value: "push-2" } }])
    allow(runtime).to receive(:dispatch_flat)

    expect(run_watch).to eq(0)
    expect(runtime).to have_received(:dispatch_flat).with("Hecks::SendTrain.Watch", run: { value: "push-1" })
    expect(runtime).to have_received(:dispatch_flat).with("Hecks::SendTrain.Watch", run: { value: "push-2" })
  end

  it "reports a boarding it cannot ask, and exits 1 for it", :aggregate_failures do
    queued.replace([{ run: { value: "push-1" } }])
    allow(runtime).to receive(:dispatch_flat).and_raise(StandardError, "gh is not logged in")

    expect { expect(run_watch).to eq(1) }.to output(/could not be asked/).to_stdout
  end

  it "refuses any argument" do
    expect { described_class.call(["extra"], root: "/repo") }.to raise_error(SystemExit)
  end
end
