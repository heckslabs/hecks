# frozen_string_literal: true

require "spec_helper"
require "support/reaping_fleet"

# `SessionCleanup.Reap` over sessions no run holds, and over a session an owner typed into. A
# session no run holds goes once it has ended, its keep window has passed and its worktree, when one
# stands, holds nothing uncommitted or unpushed; the worktree itself stays.
RSpec.describe "SessionCleanup.Reap of other sessions" do
  include_context "with a reaping fleet"

  it "keeps a run's session an owner typed into, and names it" do
    done_run(user("do it my way"))
    expect(reap).to include("r-done (a person replied (1 turns after the brief))")
  end

  it "removes a done session no run holds when it is older than a day and holds no worktree" do
    plain_session(30)
    reap
    expect(removed).to eq(["plain-1 tree=gone"])
  end

  it "removes a stopped session no run holds whose standing worktree has nothing unsaved, leaving the worktree" do
    plain_session(30, tree: scratch_worktree, state: "stopped")
    reap
    expect(removed).to eq(["plain-1 tree=present"])
  end

  it "keeps a session no run holds while its worktree holds an uncommitted file, and names it" do
    tree = scratch_worktree
    File.write(File.join(tree, "notes.txt"), "mine")
    plain_session(30, tree: tree, state: "stopped")
    expect(reap).to include("kept 1: chat (its worktree #{tree} has 1 uncommitted file(s))")
  end

  it "keeps a session no run holds while its worktree holds a commit origin lacks" do
    tree = scratch_worktree
    git(tree, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "--allow-empty", "-m", "mine")
    plain_session(30, tree: tree, state: "stopped")
    expect(reap).to include("kept 1: chat (its worktree #{tree} has 1 commit(s) origin lacks)")
  end

  it "keeps a session no run holds that ended within a day" do
    plain_session(2)
    reap
    expect(removed).to be_empty
  end
end
