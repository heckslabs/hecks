require "spec_helper"
require_relative "support/catcher_care_scratch"

# A beat of the clock asks whether the Catcher is due: once its file has stood untouched for the
# Tickets world's window it requests the Catcher's drain and detection, inside it only says why it
# waits, and a refused request is recorded by name.
RSpec.describe "the Catcher runs on a beat" do
  include CatcherCareScratch

  let(:dir) { Dir.mktmpdir("catcher-care") }
  let(:path) { File.join(dir, "catcher.db") }
  let(:asked) { [] }
  let(:refusing) { ->(_argv) { raise Hecks::Adapters::ConsoleCapture::Failure, "refused: no" } }

  after { FileUtils.rm_rf(dir) }

  it "requests the drain then the detection once the file has stood idle", :aggregate_failures do
    idle_file(45)

    expect(beat).to include("CatcherCareDue", "CatcherCareHeard", "CatcherCareRan", "CatcherCareSettled")
    expect(asked.map { |argv| argv[1] }).to eq(%w[drain.request! detection.request!])
  end

  it "runs a Catcher that has never written its file" do
    expect(beat).to include("CatcherCareDue")
  end

  it "only says why it waits inside the window", :aggregate_failures do
    idle_file(5)

    expect(beat).to include("CatcherCareDeferred", "CatcherCareDeclined")
    expect(asked).to be_empty
  end

  it "records a refused request by name" do
    idle_file(45)

    expect(beat(runner: refusing)).to include("CatcherCareRunRefused", "CatcherCareRefused")
  end
end
