# frozen_string_literal: true

require "spec_helper"
require "support/reaping_fleet"

# The sessions of a done-helper reap: each with its own transcript, last written `minutes` before
# the fixed clock, and a job in `~/.claude/jobs` whose `respawnFlags` carry the caller the pipeline
# gave it (none for the owner's), all listed done by the stand-in `claude`.
module DoneHelperFleet
  SESSIONS = { "h-old" => ["release_manager:p-walk", 45], "h-new" => ["release_manager:p-two", 10],
               "owner" => [nil, 45], "pinned" => ["release_manager:p-pin", 45],
               "orch" => ["orchestrator:stall-x", 45], "broken" => [:unreadable, 45] }.freeze

  def jobs_dir = File.join(scratch, ".claude", "jobs")

  def helper_fleet(extra = [])
    entries = SESSIONS.map { |id, (caller_name, minutes)| helper(id, caller_name, minutes) }
    File.write(File.join(scratch, "sessions.json"), JSON.generate(entries + extra))
    File.write(File.join(jobs_dir, "pins.json"), JSON.generate(%w[pinned]))
  end

  def helper(id, caller_name, minutes)
    full = "#{id}-0000-1111-2222-333344445555"
    path = File.join(scratch, ".claude", "projects", "p", "#{full}.jsonl")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, JSON.generate(user("verdict")))
    File.utime(now - (minutes * 60), now - (minutes * 60), path)
    write_job(id, caller_name)
    { id: id, sessionId: full, name: id, kind: "background", state: "done" }
  end

  def write_job(id, caller_name)
    FileUtils.mkdir_p(File.join(jobs_dir, id))
    File.write(File.join(jobs_dir, id, "state.json"), caller_name == :unreadable ? "{not json" : job_text(caller_name))
  end

  def job_text(caller_name)
    settings = JSON.generate(env: { HECKS_CALLER: caller_name }.compact, hooks: { Stop: [] })
    JSON.generate(state: "done", respawnFlags: caller_name ? ["--agent", "x", "--settings", settings] : [])
  end

  def gone = removed.map { |line| line.split.first }
end

# `SessionCleanup.Reap` removes a done helper session once the world's `remove_done_after_minutes`
# (30) has passed, and a done helper whose run ended, under the safe rules: a pinned session, the
# owner's (no caller mark), a pinned role's, a started run's and a too-recent one are kept.
RSpec.describe "SessionCleanup.Reap of done helper sessions" do
  include_context "with a reaping fleet"
  include DoneHelperFleet

  before { FileUtils.mkdir_p(jobs_dir) }

  it "removes a done helper no run holds once the set time has passed, and keeps every other" do
    helper_fleet
    reap
    expect(gone).to eq(%w[h-old])
  end

  it "keeps a done helper whose run is still started" do
    launch("agent_run.dispatch!", "run.value=r-live", "repo.value=#{scratch}", "brief.value=go", "--wait")
    helper_fleet([helper("stand-in-session", "release_manager:r-live", 45)])
    reap
    expect(gone).not_to include("stand-in-session")
  end

  it "removes a done helper whose run has ended" do
    done_run
    reap
    expect(removed).to eq(["stand-in-session tree=gone"])
  end
end
