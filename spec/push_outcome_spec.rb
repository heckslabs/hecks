require "spec_helper"
require "hecks/hecks/adapters/git_train"
require "hecks/hecks/adapters/push_recorder"
require "hecks/hecks/adapters/git_launcher"
require "hecks/hecks/adapters/desktop_alert"

# A boarding's outcome reaches the `PushRecords` port through the booted Hecks domain: each way a
# boarding ends asks the port once, with the run the port records from, and a recording that is
# refused leaves the push as it ended. The train, the launcher refresh, the deploy announcement and
# the recorder are stand-ins, so nothing is pushed, moved, shown or recorded.
RSpec.describe "a boarding's outcome, recorded through the PushRecords port" do
  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false)
  end

  let(:recorder) { instance_double(Hecks::Adapters::PushRecorder, record_outcome: { report: { value: "recorded" } }) }
  let(:train) { instance_double(Hecks::Adapters::GitTrain) }

  before do
    allow(Hecks::Adapters::GitTrain).to receive(:new).and_return(train)
    allow(Hecks::Adapters::PushRecorder).to receive(:new).and_return(recorder)
    allow(Hecks::Adapters::GitLauncher).to receive(:new)
      .and_return(instance_double(Hecks::Adapters::GitLauncher, refresh: { report: { value: "left" } }))
    allow(Hecks::Adapters::DesktopAlert).to receive(:new)
      .and_return(instance_double(Hecks::Adapters::DesktopAlert, announce: { report: { value: "shown" } }))
  end

  def answer(outcome, commits: 3)
    { outcome: { value: outcome }, checkout: { value: "/checkout" }, boarded: { value: "b0a7ded" },
      pushed: { value: "5ec0ffee" }, commits: { value: commits }, report: { value: "pushing #{commits} commits" } }
  end

  def board(run)
    @hecks.dispatch_flat("Hecks::SendTrain.Board", run: { value: run }, checkout: { value: "/checkout" },
                                                   confirm: { value: true })
    @hecks.query("Hecks::SendTrain.Outcome", run: { value: run }).first
  end

  def recorded = have_received(:record_outcome)

  it "records a push, with its commit, its commit count and its report", :aggregate_failures do
    allow(train).to receive(:carry).and_return(answer("pushed"))
    board("o-pushed")

    expect(recorder).to recorded.once.with(hash_including(status: "pushed", pushed: { value: "5ec0ffee" },
                                                          commits: { value: 3 }, checkout: { value: "/checkout" }))
  end

  it "records a boarding an earlier push carried" do
    allow(train).to receive(:carry).and_return(answer("carried"))
    board("o-carried")

    expect(recorder).to recorded.once.with(hash_including(status: "carried"))
  end

  it "records a boarding that faulted, with the reason" do
    allow(train).to receive(:carry).and_raise(Hecks::Adapters::ConsoleCapture::Failure, "the branch moved")
    board("o-faulted")

    expect(recorder).to recorded.once.with(hash_including(status: "faulted", refusal: { value: /the branch moved/ }))
  end

  it "leaves a push pushed when the recording is refused" do
    allow(train).to receive(:carry).and_return(answer("pushed"))
    allow(recorder).to receive(:record_outcome).and_raise(Hecks::Adapters::ConsoleCapture::Failure, "no launcher")

    expect(Hecks::Runtime::Value.materialize(board("o-unrecorded"))).to include(status: "pushed")
  end
end
