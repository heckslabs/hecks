# frozen_string_literal: true

require "spec_helper"
require "support/reaping_fleet"

# `SessionCleanup.Reap` over a finished run: its worktree is retired before its session is removed,
# and a run whose Work is still queued is kept and named.
RSpec.describe "SessionCleanup.Reap of a finished run" do
  include_context "with a reaping fleet"

  it "retires a worktree holding only scratch, then removes its session", :aggregate_failures do
    done_run(tree: scratch_worktree)
    expect(reap).to start_with("removed 1 sessions and 1 worktrees; kept 0")
    expect(removed).to eq(["stand-in-session tree=gone"])
  end

  it "keeps a run whose Work is still queued, and names it" do
    allow(Hecks::Adapters::Dispatching::WorkItems).to(receive(:new).and_wrap_original do |original, *args|
      original.call(*args).tap { |items| allow(items).to receive(:work_status).and_return("planned") }
    end)
    done_run
    expect(reap).to include("kept 1: r-done (Work still queued)")
  end
end
