require "spec_helper"
require_relative "support/watched_train"

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

  it "refuses to watch a boarding that already pushed, reading no pull request", :aggregate_failures do
    board_and_watch
    allow(train).to receive(:observe).and_return(WatchedTrain::MERGED)
    send_train("Watch")
    expect { send_train("Watch") }.to raise_error(/only a queued or red boarding has a pull request to watch/)
    expect(train).to have_received(:observe).twice
  end
end
