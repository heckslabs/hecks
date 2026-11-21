# frozen_string_literal: true

require "support/train_scratch_repo"

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
