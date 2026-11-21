# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_stages"
require_relative "support/board_rows"
require_relative "support/glance_facts"

# The board's `Glance`, what waits on a person. The `StuckKind` and `Verdict` rows decide
# the members and how long is too long; the adapter only reshapes the facts it is handed.
RSpec.describe Hecks::Adapters::PipelineBoard::GlanceRows, ".build" do
  include BoardRows
  include GlanceFacts

  it "lists a question put to the owner, waiting on the owner as a person" do
    expect(entry(sessions: [GlanceFacts::OWNER_ASK], kind: "owner_ask"))
      .to include(group: "waiting on a person", waits_on: "owner", waits_on_kind: "person", owner_run: "r1")
  end

  it "lists a blocked session awaiting a reply, waiting on the orchestrator as a role" do
    expect(entry(sessions: [GlanceFacts::BLOCKED], kind: "blocked_run"))
      .to include(group: "waiting on a person", waits_on: "orchestrator", waits_on_kind: "role")
  end

  it "lists an approval only the owner can give" do
    expect(entry(approvals: [{ finding: "f1", title: "release v8" }], kind: "approval_awaited"))
      .to include(group: "waiting on a person", waits_on: "owner", what: /release v8/)
  end
end
