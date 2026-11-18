require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_settled_looks"

# A train stall filed while its boarding waited is abandoned once the boarding settles: its pull
# request merged (`BranchPushed`) or closed unmerged (`BoardingClosed`). A red verdict settles
# nothing, since the pull request stays open.
RSpec.describe "StallWatch train stalls whose boarding settled" do
  include_context "with a stall watch tap"
  include StallSettledLooks

  let(:run) { "b9e51036-0000-4000-8000-00000000c3d4" }

  def abandoned_reasons = watching.abandoned(run: "look").map { |row| row[:reason] }

  def file_unmerged(*after)
    append("BoardingQueued", run, "Hecks::SendTrain", 100)
    append("StallFiled", "stall-train-unmerged-#{run}", "Hecks::Stall", 50)
    after.each { |event| append(event, run, "Hecks::SendTrain", 5) }
  end

  it "abandons a filed train-unmerged stall once its pull request merged" do
    file_unmerged("BranchPushed")

    expect(abandoned_reasons)
      .to eq(["Hecks::SendTrain #{run} can no longer be answered: it settled: Hecks::SendTrain recorded BranchPushed"])
  end

  it "abandons a filed train-unmerged stall once its pull request closed unmerged" do
    file_unmerged("BoardingClosed")

    expect(abandoned_reasons.first).to end_with("Hecks::SendTrain recorded BoardingClosed")
  end

  it "keeps a filed train-unmerged stall while its pull request is open" do
    file_unmerged

    expect(abandoned_reasons).to be_empty
  end

  it "abandons a filed train-checks-failed stall once its pull request merged" do
    append("TrainChecksFailed", run, "Hecks::SendTrain", 20)
    append("StallFiled", "stall-train-checks-failed-#{run}", "Hecks::Stall", 19)
    append("BranchPushed", run, "Hecks::SendTrain", 5)

    expect(watching.abandoned(run: "look").map { |row| row[:stall] }).to eq(["stall-train-checks-failed-#{run}"])
  end
end
