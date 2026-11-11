# frozen_string_literal: true

require "spec_helper"
require "support/reaping_fleet"

# `SessionCleanup.Reap` over sessions no run holds, and over a session an owner typed into.
RSpec.describe "SessionCleanup.Reap of other sessions" do
  include_context "with a reaping fleet"

  it "keeps a run's session an owner typed into, and names it" do
    done_run(user("do it my way"))
    expect(reap).to include("r-done (a person replied, or the transcript cannot be read)")
  end

  it "removes a done session no run holds when it is older than a day and holds no worktree" do
    plain_session(30)
    reap
    expect(removed).to eq(["plain-1 tree=gone"])
  end

  it "keeps a session no run holds while its worktree stands, and names it" do
    plain_session(30, tree: scratch_worktree)
    expect(reap).to include("kept 1: chat (worktree")
  end

  it "keeps a session no run holds that ended within a day" do
    plain_session(2)
    reap
    expect(removed).to be_empty
  end
end
