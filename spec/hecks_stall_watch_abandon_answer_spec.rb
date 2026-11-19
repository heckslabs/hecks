require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_session_looks"

# An abandoned stall asks the session its wake started to end its turn, and a stall that started no
# session still has its work item dropped: the refused answer does not stop the drop.
RSpec.describe "StallWatch abandoned stall answers" do
  include_context "with a stall watch tap"
  include StallSessionLooks

  it "asks an abandoned stall's session to end its turn" do
    file_begin_then_settle("w1")

    expect(events_named("AnswerRequested")).to eq(1)
  end

  it "still drops the work item when the abandoned stall started no session to answer", :aggregate_failures do
    file_then_finish("w1")

    expect(events_named("AnswerRequested")).to eq(0)
    expect(work_status("stall-agent-run-session-w1")).to eq("dropped")
  end
end
