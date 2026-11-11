require "spec_helper"
require "hecks/hecks/adapters/git_train"
require "hecks/hecks/adapters/git_launcher"
require "hecks/hecks/adapters/desktop_alert"

# Boots the Hecks domain with the push train's adapters stubbed: a boarding is queued as a pull
# request, and watching it answers whatever the example sets.
module WatchedTrain
  KEY = { value: "watch-1" }.freeze
  QUEUED = { outcome: { value: "queued" }, checkout: { value: "/repo" }, boarded: { value: "abc" },
             commits: { value: 1 }, report: { value: "queued" } }.freeze
  FAILED = { outcome: { value: "checks_failed" }, report: { value: "rspec 1/4, lint" } }.freeze
  MERGED = { outcome: { value: "merged" }, checkout: { value: "/repo" }, boarded: { value: "abc" },
             pushed: { value: "def" }, report: { value: "merged" } }.freeze

  def stub_train(observe)
    train = instance_double(Hecks::Adapters::GitTrain, carry: QUEUED, observe: observe)
    allow(Hecks::Adapters::GitTrain).to receive(:new).and_return(train)
    allow(Hecks::Adapters::GitLauncher).to receive(:new).and_return(double(refresh: { report: { value: "ok" } }))
    allow(Hecks::Adapters::DesktopAlert).to receive(:new).and_return(double(announce: { report: { value: "ok" } }))
    train
  end

  def send_train(command, **args) = @hecks.dispatch_flat("Hecks::SendTrain.#{command}", run: KEY, **args)

  def boarding = @hecks.query("Hecks::SendTrain.Outcome", run: KEY).first

  def board_and_watch
    @hecks = boot_hecks_in_memory
    send_train("Board", confirm: { value: true })
    send_train("Watch")
  end
end

# A watched boarding whose pull request ended with failed checks is recorded as red, naming the
# failed jobs; a red boarding stays in the watch, and a merge after it is still recorded.
RSpec.describe "SendTrain.Watch recording a queued boarding's pull request" do
  include WatchedTrain

  let!(:train) { stub_train(WatchedTrain::FAILED) }

  it "records failed checks as red, with the failed jobs as the report", :aggregate_failures do
    board_and_watch
    expect([boarding[:status], boarding[:report].value]).to eq(["red", "rspec 1/4, lint"])
  end

  it "keeps a red boarding in the queued query" do
    board_and_watch
    expect(@hecks.query("Hecks::SendTrain.Queued").map { |row| row[:id] }).to include("watch-1")
  end

  it "records the merge of a red boarding", :aggregate_failures do
    board_and_watch
    allow(train).to receive(:observe).and_return(WatchedTrain::MERGED)
    send_train("Watch")
    expect(boarding).to include(status: "pushed")
  end
end
