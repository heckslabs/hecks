require "spec_helper"
require_relative "support/merged_worktrees_repo"

# The reap retires a coder's worktree once its branch is on main and nothing in it is at risk.
RSpec.describe Hecks::Adapters::ClaudeCleaning::MergedWorktrees, "#sweep" do
  include_context "with a repository of coder worktrees"

  context "when the branch is on main and nothing is at risk" do
    it "retires a merged, clean worktree older than the window" do
      seat("landed")
      expect(sweep[:removed]).to eq(["landed"])
    end

    it "retires at most the cap in one sweep" do
      3.times { |i| seat("landed-#{i}") }
      expect(sweep(cap: 2)[:removed].length).to eq(2)
    end

    it "keeps a worktree the retirement refuses, and goes on to the next" do
      seat("a-refused")
      seat("b-landed")
      refusing = ->(path) { File.basename(path) == "a-refused" ? raise("holds work") : retired << "b" }
      expect(sweep(retire: refusing).values_at(:removed, :kept).map { |l| l.flatten.first }).to eq(%w[b-landed a-refused])
    end
  end

  context "when something is at risk" do
    it "keeps a worktree whose Work is still open, however merged it looks" do
      seat("fresh-coder")
      open_work << "fresh-coder"
      expect(kept).to eq(["fresh-coder"])
    end

    it "keeps a worktree younger than the window" do
      seat("young")
      expect(sweep(now: Time.now)[:kept].map(&:first)).to eq(["young"])
    end

    it "keeps a worktree with an uncommitted file" do
      File.write(File.join(seat("dirty"), "scratch.txt"), "x")
      expect(kept).to eq(["dirty"])
    end

    it "keeps a worktree with a commit origin lacks" do
      commit(seat("unlanded"), "more")
      expect(kept).to eq(["unlanded"])
    end

    it "keeps a worktree that is not on a branch" do
      git(root, "worktree", "add", "-q", "--detach", File.join(root, ".claude", "worktrees", "loose"))
      expect(kept).to eq(["loose"])
    end
  end

  context "when a worktree stands outside the checkout" do
    it "retires a merged, clean one under a listed directory by the same rules" do
      seat_outside("landed-away")
      expect(sweep(outside: [outside_dir])[:removed]).to eq(["landed-away"])
    end

    it "leaves it alone when no outside directory is listed" do
      seat_outside("landed-away")
      expect(sweep[:removed]).to eq([])
    end

    it "keeps one that holds an uncommitted file or a commit origin lacks" do
      File.write(File.join(seat_outside("dirty-away"), "scratch.txt"), "x")
      commit(seat_outside("unlanded-away"), "more")
      expect(sweep(outside: [outside_dir])[:kept].map(&:first)).to eq(%w[dirty-away unlanded-away])
    end

    it "keeps one whose Work is still open" do
      seat_outside("open-away")
      open_work << "open-away"
      expect(sweep(outside: [outside_dir])[:kept].map(&:first)).to eq(["open-away"])
    end

    it "does not match a sibling directory that only shares the prefix" do
      seat_outside("landed-away", parent: "#{outside_dir}-old")
      expect(sweep(outside: [outside_dir])[:removed]).to eq([])
    end

    it "counts in-tree and outside worktrees against one cap" do
      seat("in-tree")
      seat_outside("away")
      expect(sweep(outside: [outside_dir], cap: 1)[:removed].length).to eq(1)
    end
  end
end
