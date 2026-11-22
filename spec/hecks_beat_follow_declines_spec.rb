# frozen_string_literal: true

require "spec_helper"
require "support/train_scratch_repo"
require "hecks/hecks/adapters/main_integration"

# The beat's follow step names, in one line of the overrun log, every reason it leaves the train
# copy where it is; a copy that is level, or that the step moves, says nothing.
module DeclinedFollow
  include TrainScratchRepo

  FOLLOW = Hecks::Adapters::MainIntegration::FollowMain

  def home = @home ||= Dir.mktmpdir("beat-follow-home")

  def copy = @copy ||= File.join(Dir.mktmpdir("beat-follow"), "hecks-train")

  def log = File.join(home, ".claude", "hecks-dev", "train-beat.overrun.log")

  def said = File.file?(log) ? File.read(log) : ""

  def behind_main
    git("init", "-q", "-b", "main")
    commit("first")
    git("worktree", "add", "-q", "--detach", copy, "HEAD")
    commit("second")
  end

  def follow = Open3.capture3({ "HOME" => home }, "sh", "-c", FOLLOW.step, chdir: copy)

  def copy_head = git("rev-parse", "HEAD", dir: copy)

  # Starts a process from the copy whose command names `word`, and answers once it is running.
  def run_from_copy(word)
    ready, writer = IO.pipe
    @pid = Process.spawn("ruby", "-e", "puts 1; $stdout.flush; sleep 30", word, chdir: copy, out: writer)
    ready.gets
  end

  def stop_copy_process = @pid && Process.kill("TERM", @pid) && Process.wait(@pid)
end

RSpec.describe "the beat copy that cannot be brought level with main" do
  include DeclinedFollow

  before { behind_main }

  after { stop_copy_process }

  it "says a copy on a branch is left alone" do
    git("checkout", "-q", "-b", "work", dir: copy)
    follow
    expect(said).to include(DeclinedFollow::FOLLOW::BRANCH)
  end

  it "stays put while an advance runs from it" do
    run_from_copy("advance")
    stayed = copy_head
    follow
    expect(copy_head).to eq(stayed)
  end

  it "says so in the overrun log while an advance runs from it" do
    run_from_copy("advance")
    follow
    expect(said).to include(DeclinedFollow::FOLLOW::BUSY)
  end

  it "says when main cannot be found", :aggregate_failures do
    git("branch", "-m", "main", "trunk")
    follow
    expect(said).to include(DeclinedFollow::FOLLOW::NO_MAIN)
  end

  it "says nothing when it moves the copy to main", :aggregate_failures do
    follow
    expect(copy_head).to eq(git("rev-parse", "main"))
    expect(said).to eq("")
  end

  it "says nothing about a copy already level with main" do
    git("checkout", "-q", "--detach", "main", dir: copy)
    follow
    expect(said).to eq("")
  end
end
