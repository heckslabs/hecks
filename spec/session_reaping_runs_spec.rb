# frozen_string_literal: true

require "spec_helper"
require "support/reaping_fleet"
require "hecks/checkout_caches"

# `SessionCleanup.Reap` over a finished run: its worktree is retired before its session is removed,
# and a run whose Work is still queued is kept and named.
RSpec.describe "SessionCleanup.Reap of a finished run" do
  include_context "with a reaping fleet"

  it "retires a worktree holding only scratch, then removes its session", :aggregate_failures do
    done_run(tree: scratch_worktree)
    expect(reap).to start_with("removed 1 sessions and 1 worktrees; kept 0")
    expect(removed).to eq(["stand-in-session tree=gone"])
  end

  # The Cargo slot and compiled-Ruby cache a worktree kept under a cache in `scratch`, made, with
  # a finished run on that worktree.
  def caches_of(tree)
    allow(Hecks::CacheDir).to receive(:root).and_return(File.join(scratch, ".cache", "hecks"))
    dirs = [Hecks::RustBuild::TargetDir.shared(Hecks::CheckoutSlug.slug(tree)), Hecks::BootCache.dir(tree)]
    FileUtils.mkdir_p(dirs)
    done_run(tree: tree)
    dirs
  end

  it "removes the retired worktree's Cargo slot and compiled-Ruby cache" do
    caches = caches_of(scratch_worktree)
    reap
    expect(caches.map { |dir| File.exist?(dir) }).to eq([false, false])
  end

  it "keeps a run whose Work is still queued, and names it" do
    allow(Hecks::Adapters::Dispatching::WorkItems).to(receive(:new).and_wrap_original do |original, *args|
      original.call(*args).tap { |items| allow(items).to receive(:work_status).and_return("planned") }
    end)
    done_run
    expect(reap).to include("kept 1: r-done (Work still queued)")
  end

  it "removes a finished run's session the listing reads working while idle" do
    done_run(listed: %w[working idle])
    expect(reap).to start_with("removed 1 sessions")
  end
end
