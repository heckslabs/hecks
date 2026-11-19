# frozen_string_literal: true

require "spec_helper"
require_relative "support/train_scratch_repo"
require "hecks/hecks/adapters/git"
require "hecks/hecks/adapters/git_train"
require "hecks/hecks/adapters/dispatching/checkout"
require "hecks/adapters/driven/worktree_overlay"

# A command resolves the checkout it stands in, so a path argument is an override and never a
# requirement: from a scratch primary checkout and a linked worktree of it, both resolve the same
# primary, a branch resolves to the worktree holding it, and the push train boards from there.
RSpec.describe Hecks::Adapters::Dispatching::Checkout, :io do
  include TrainScratchRepo

  let(:primary) { File.realpath(repo) }
  let(:linked) { File.join(primary, "linked") }
  let(:train) { Hecks::Adapters::GitTrain.new }

  before do
    git("init", "-q", "-b", "main")
    commit("first")
    git("worktree", "add", "-q", "-b", "feature", linked)
  end

  after { FileUtils.remove_entry(repo) }

  # The checkout `GitTrain#landings` reads from, when the process stands in `cwd`.
  def train_checkout(cwd, **held)
    seen = nil
    allow(Hecks::Adapters::GitTrain::Landings).to receive(:new) do |_git, dir|
      seen = dir
      instance_double(Hecks::Adapters::GitTrain::Landings, list: [])
    end
    Dir.chdir(cwd) { train.landings(boarded: { value: head }, **held) }
    seen
  end

  # What the push train says of local main once `feature`'s tip is pushed.
  def catch_up_main
    Hecks::Adapters::GitTrain::LocalBranch.new(Hecks::Adapters::Git.new, linked, "main").catch_up(git("rev-parse", "feature"))
  end

  it "resolves the primary checkout from a linked worktree" do
    expect(described_class.main(linked)).to eq(primary)
  end

  it "resolves the primary checkout from the primary itself" do
    expect(described_class.main(primary)).to eq(primary)
  end

  it "agrees with the worktree overlay's reading of the worktree's .git file" do
    expect(Hecks::Adapters::WorktreeOverlay.main_checkout(linked)).to eq(described_class.main(linked))
  end

  it "resolves main to the primary checkout from a linked worktree" do
    expect(described_class.holding("main", linked)).to eq(primary)
  end

  it "resolves a branch to the worktree holding it" do
    expect(described_class.holding("feature", primary)).to eq(linked)
  end

  it "answers a directory git names no repository for with that directory itself" do
    Dir.mktmpdir { |outside| expect(described_class.main(outside)).to eq(outside) }
  end

  it "resolves a branch no worktree holds to the primary checkout" do
    expect(described_class.holding("absent", linked)).to eq(primary)
  end

  describe "the push train" do
    it "boards main from the primary checkout when run from a linked worktree with no path" do
      expect(train_checkout(linked)).to eq(primary)
    end

    it "takes a checkout that is named over the resolution" do
      expect(train_checkout(primary, checkout: { value: linked })).to eq(linked)
    end

    it "leaves a dirty primary's main where it is instead of moving it", :aggregate_failures do
      commit("ahead", dir: linked)
      File.write(File.join(primary, "first"), "edited")
      expect(catch_up_main).to eq("local main has uncommitted changes in #{primary}; it is left behind")
      expect(git("rev-parse", "main")).not_to eq(git("rev-parse", "feature"))
    end
  end
end
