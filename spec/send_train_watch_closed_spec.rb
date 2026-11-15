require "spec_helper"
require_relative "support/watched_train"

# A watched boarding whose pull request closed unmerged can never merge: it is recorded closed, a
# settled state, so the next watch no longer reads it and no stall stays open for it.
RSpec.describe "SendTrain.Watch recording a boarding whose pull request closed unmerged" do
  include WatchedTrain

  before { stub_train(WatchedTrain::CLOSED) }

  it "records the boarding closed, with the reason as the report", :aggregate_failures do
    board_and_watch
    expect([boarding[:status], boarding[:report].value]).to eq(["closed", "train/main-abc was closed unmerged"])
  end

  it "leaves a closed boarding out of the queued query" do
    board_and_watch
    expect(@hecks.query("Hecks::SendTrain.Queued").map { |row| row[:id] }).not_to include("watch-1")
  end
end
