require "spec_helper"
require "open3"
require_relative "support/stand_in_claude"

# A session `claude agents` lists as stopped while its job still reads `working` has ended without
# saying so. Through the booted Hecks domain: a coder whose worktree holds nothing to lose ends its
# run `stopped` on the next check; one with unsaved files or commits origin lacks, and any other
# role, stays started. The stand-in `claude` lists the session with the state a spec writes, and
# each coder's worktree is a clone of a bare origin in a temporary directory.
RSpec.describe "AgentRun: a session listed stopped while its job reads working" do
  include_context "with a stand-in claude"

  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  def git(dir, *args) = Open3.capture2e("git", "-C", dir, "-c", "user.email=a@b.c", "-c", "user.name=spec", *args)

  def worktree
    origin = File.join(scratch, "origin.git")
    clone = File.join(scratch, "clone")
    Open3.capture2e("git", "init", "--bare", "-b", "main", origin)
    Open3.capture2e("git", "clone", origin, clone)
    git(clone, "commit", "--allow-empty", "-m", "first")
    git(clone, "push", "origin", "main")
    clone
  end

  def listed(state)
    File.write(File.join(scratch, "sessions.json"), JSON.generate([{ id: "stand-in-session", state: state }]))
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def check(run) = JSON.parse(launch("agent_run.check!", "to=#{run}", "--wait").first.to_s).fetch("state")

  def stopped_run(run, agent, repo)
    launch("agent_run.dispatch!", "run.value=#{run}", "repo.value=#{repo}", "brief.value=say ok",
           "agent.value=#{agent}", "--wait")
    check(run)
    listed("stopped")
    check(run)
  end

  it "ends a coder's run stopped when its worktree holds nothing to lose" do
    expect(stopped_run("r-clean-coder", "coder", worktree)).to include("status" => "finished", "condition" => "stopped")
  end

  it "leaves a coder with an uncommitted file started" do
    tree = worktree
    File.write(File.join(tree, "notes.txt"), "unsaved")

    expect(stopped_run("r-dirty-coder", "coder", tree)).to include("status" => "started")
  end

  it "leaves a coder with a commit origin lacks started" do
    tree = worktree
    git(tree, "commit", "--allow-empty", "-m", "unpushed")

    expect(stopped_run("r-ahead-coder", "coder", tree)).to include("status" => "started")
  end

  it "leaves a coder whose worktree cannot be read as a git tree started" do
    expect(stopped_run("r-unreadable-coder", "coder", scratch)).to include("status" => "started")
  end

  it "leaves another role's run started" do
    expect(stopped_run("r-stopped-reviewer", "reviewer", worktree)).to include("status" => "started")
  end
end
