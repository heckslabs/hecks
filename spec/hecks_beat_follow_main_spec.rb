# frozen_string_literal: true

require "spec_helper"
require "support/train_scratch_repo"
require "hecks/hecks/adapters/main_integration"

# The beat job's follow step, run by a real shell against a scratch repository and a detached copy.
RSpec.describe "the beat job's follow step" do
  include TrainScratchRepo

  let(:copy) { File.join(Dir.mktmpdir("beat-follow"), "hecks-train") }

  before do
    git("init", "-q", "-b", "main")
    commit("first")
    git("worktree", "add", "-q", "--detach", copy, "HEAD")
    commit("second")
  end

  def follow = Open3.capture3("sh", "-c", Hecks::Adapters::MainIntegration::BeatSchedule::FOLLOW_MAIN, chdir: copy)

  it "moves a clean detached copy behind main to main" do
    follow
    expect(git("rev-parse", "HEAD", dir: copy)).to eq(git("rev-parse", "main"))
  end

  it "leaves a copy with a tracked change where it is" do
    File.write(File.join(copy, "first"), "changed")
    follow
    expect(git("rev-parse", "HEAD", dir: copy)).to eq(git("rev-parse", "HEAD~1"))
  end

  it "leaves a copy ahead of main where it is" do
    commit("ahead", dir: copy)
    ahead = git("rev-parse", "HEAD", dir: copy)
    follow
    expect(git("rev-parse", "HEAD", dir: copy)).to eq(ahead)
  end

  it "leaves a diverged copy where it is" do
    commit("other", dir: copy)
    other = git("rev-parse", "HEAD", dir: copy)
    follow
    expect(git("rev-parse", "HEAD", dir: copy)).to eq(other)
  end

  it "ends well when the copy is on a branch" do
    git("checkout", "-q", "-b", "work", dir: copy)
    expect(follow.last).to be_success
  end
end
