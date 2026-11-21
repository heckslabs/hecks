# frozen_string_literal: true

require "spec_helper"
require "support/train_scratch_repo"
require "hecks/hecks/adapters/main_integration"

# A scratch repository whose detached copy sits on a commit that local main then rewrites, and the
# beat's follow step run against that copy with a throwaway home for its overrun log.
module RewrittenMainCopy
  include TrainScratchRepo

  def home = @home ||= Dir.mktmpdir("beat-follow-home")

  def copy = @copy ||= File.join(Dir.mktmpdir("beat-follow"), "hecks-train")

  def log = File.join(home, ".claude", "hecks-dev", "train-beat.overrun.log")

  def rewrite_main
    git("init", "-q", "-b", "main")
    commit("first")
    commit("second")
    git("worktree", "add", "-q", "--detach", copy, "HEAD")
    git("commit", "-q", "--amend", "-m", "second, rewritten")
  end

  def follow
    step = Hecks::Adapters::MainIntegration::FollowMain.step
    Open3.capture3({ "HOME" => home }, "sh", "-c", step, chdir: copy)
  end

  def copy_head = git("rev-parse", "HEAD", dir: copy)
end

# The beat copy after local main is rewritten, as `LinkedTree.pull_main!` rewrites it: the copy's
# head is off main's history, and `Clearance.Grant` refuses a head that is not main's.
RSpec.describe "the beat copy after local main is rewritten" do
  include RewrittenMainCopy

  before { rewrite_main }

  it "is not an ancestor of the rewritten main before the follow" do
    expect { git("merge-base", "--is-ancestor", copy_head, "main") }.to raise_error(/git/)
  end

  it "follows to the rewritten tip, so the clearance given head == main holds" do
    follow
    expect(copy_head).to eq(git("rev-parse", "main"))
  end

  it "leaves a copy with a tracked change where it is and says so in the overrun log", :aggregate_failures do
    File.write(File.join(copy, "first"), "changed")
    stayed = copy_head
    follow
    expect(copy_head).to eq(stayed)
    expect(File.read(log)).to include(Hecks::Adapters::MainIntegration::FollowMain::REFUSAL)
  end

  it "does not count an untracked file as a change" do
    File.write(File.join(copy, "untracked"), "x")
    follow
    expect(copy_head).to eq(git("rev-parse", "main"))
  end
end
