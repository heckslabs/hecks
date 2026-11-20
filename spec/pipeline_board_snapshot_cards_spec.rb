# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_stages"
require_relative "support/board_rows"
require_relative "support/board_state_fixture"

# The cards and lines the `Snapshot` row holds beside its readings, each built as the value
# object the bluebook declares for it.
RSpec.describe "PipelineBoard Snapshot cards" do
  include BoardRows

  let(:snapshot) do
    Hecks::Adapters::PipelineBoard::SnapshotRows.build(BoardStateFixture.state, train_prs: [BoardStateFixture::PULL],
                                                                                release:   { tag: "v7.0.0" })
  end

  it "judges an open train pull request by the Train PR rows" do
    expect(built("TrainCard", snapshot[:train].first)).to include(pr: 7, green: 3, red: 0, state: "working")
  end

  it "names the policies that reacted to an event" do
    expect(built("EventLine", snapshot[:events].first)).to include(name: "WorkFinished", reactions: "CloseWhenDone")
  end

  it "carries the latest release's tag on the ReleaseCard" do
    expect(built("ReleaseCard", snapshot[:release])).to include(latest_tag: "v7.0.0", next_version: "")
  end

  it "says how long a run's session has written nothing on its RunCard" do
    expect(built("RunCard", snapshot[:runs].last)).to include(run: "r2", role: "coder", idle_seconds: 1200)
  end
end
