# frozen_string_literal: true

require "spec_helper"
require_relative "support/pipeline_board_world"

# The owner's queue: of the sessions the Claude listing calls blocked, only the ones that ask the
# owner are marked `owner`; every other blocked session carries the word for what it is.
RSpec.describe Hecks::Adapters::PipelineBoard::OwnerQueue do
  let(:root) { "/work/hecks" }
  let(:open_work) { [{ slug: "live-item", status: "started", title: "A live item" }] }

  def blocked(extra = {})
    { id: "s1", name: "coder", status: "blocked", run: "r1", work_item: "live-item", detail: "working on it",
      cwd: "#{root}/.claude/worktrees/live-item", context: { said: "tests are running" } }.merge(extra)
  end

  def marked(session, work = open_work) = described_class.mark([session], work, root).first

  it "does not list a blocked session whose Work item has finished", :aggregate_failures do
    found = marked(blocked(work_item: "gone-item"))
    expect(found[:owner]).to be(false)
    expect(found[:held]).to eq("finished leftover")
  end

  it "does not label a blocked session with a plain progress message as waiting on you", :aggregate_failures do
    found = marked(blocked)
    expect(found[:owner]).to be(false)
    expect(found[:held]).to eq("stranded run")
  end

  it "lists a session for which a needs-an-answer Work item is open" do
    work = open_work + [{ slug: "needs-answer-r1", status: "planned", title: "needs an answer: r1" }]
    expect(marked(blocked, work)[:owner]).to be(true)
  end

  it "lists a session whose latest message begins with the owner marker" do
    expect(marked(blocked(context: { said: "[owner] which account do I use?" }))[:owner]).to be(true)
  end

  it "names a session that waits on a plan review" do
    expect(marked(blocked(context: { said: "[review] board-x" }))[:held]).to eq("waiting on a review verdict")
  end

  it "leaves a session of another repository out", :aggregate_failures do
    found = marked(blocked(run: "", work_item: "", cwd: "/work/emaho"))
    expect(found[:owner]).to be(false)
    expect(found[:held]).to eq("other repo")
  end

  it "never calls a session a leftover when the open Work items could not be read" do
    expect(marked(blocked(work_item: "gone-item"), { unknown: "no store" })[:held]).to eq("stranded run")
  end

  it "counts only the owner's queue as waiting on you", :aggregate_failures do
    list = described_class.mark([blocked, blocked(context: { said: "[owner] pick" })], open_work, root)
    expect(list.count { |s| described_class.waiting?(s) }).to eq(1)
    expect(described_class.mark([], open_work, root).count { |s| described_class.waiting?(s) }).to eq(0)
  end
end
