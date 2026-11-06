require "spec_helper"
require "support/stand_in_claude"
require "fileutils"
require "json"
require "open3"

# `SessionCleanup.Removable` and `SessionCleanup.RemoveSafe` through the booted Hecks domain. The
# stand-in `claude` lists the sessions and records each `rm` in a log, `HOME` points at a scratch
# directory holding the transcripts, and the worktrees are throwaway git clones, so no real session
# is listed or removed.
RSpec.describe "SessionCleanup through the Cleaning port" do
  include_context "with a stand-in claude"

  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false)
  end

  def git(dir, *)
    out, status = Open3.capture2e("git", "-C", dir, *)
    raise "git #{[*].join(" ")} failed: #{out}" unless status.success?
  end

  # A clone of a bare origin: clean, with an uncommitted file, or with a commit origin lacks.
  def worktree(name, change = nil)
    origin = File.join(scratch, "#{name}-origin.git")
    path = File.join(scratch, "trees", name)
    Open3.capture2e("git", "init", "--bare", "-b", "main", origin)
    Open3.capture2e("git", "clone", origin, path)
    commit(path, "seed")
    git(path, "push", "origin", "main")
    send(change, path) if change
    path
  end

  def commit(path, message)
    File.write(File.join(path, message), message)
    git(path, "add", ".")
    git(path, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-m", message)
  end

  def dirty(path) = File.write(File.join(path, "loose"), "x")
  def ahead(path) = commit(path, "unpushed")

  def session(id, state, tree)
    transcript(id, tree)
    { id: id[0, 4], sessionId: id, name: "n-#{id[0, 4]}", kind: "background", state: state }
  end

  def transcript(id, tree)
    dir = File.join(scratch, ".claude", "projects", "p")
    FileUtils.mkdir_p(dir)
    entry = tree == :none ? { type: "user" } : { type: "worktree-state", worktreeSession: { worktreePath: tree } }
    File.write(File.join(dir, "#{id}.jsonl"), JSON.generate(entry))
  end

  def list(*entries) = File.write(File.join(scratch, "sessions.json"), JSON.generate(entries))

  def fleet
    list(session("aaaa-clean", "done", worktree("clean")), session("bbbb-dirty", "done", worktree("dirty", :dirty)),
         session("cccc-ahead", "stopped", worktree("ahead", :ahead)), session("dddd-gone", "done", File.join(scratch, "gone")),
         session("eeee-none", "done", :none), session("ffff-work", "working", :none), session("gggg-wait", "blocked", :none))
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks").first.to_s

  def removed = File.exist?(File.join(scratch, "rm.log")) ? File.readlines(File.join(scratch, "rm.log"), chomp: true) : []

  it "marks each session safe or kept with the reason, and removes nothing", :aggregate_failures do
    fleet
    out = launch("session_cleanup.removable")

    expect(out).to include("aaaa  plain n-aaaa  safe", "dddd  plain n-dddd  safe", "eeee  plain n-eeee  safe")
    expect(out).to include("uncommitted", "origin lacks", "still working", "waiting on a person")
    expect(removed).to be_empty
  end

  it "removes only the safe sessions, without discarding unpushed work", :aggregate_failures do
    fleet
    out = launch("session_cleanup.remove_safe!", "run.value=s1", "--confirm", "--wait")

    expect(removed).to contain_exactly("aaaa", "dddd", "eeee")
    expect(out).to include("kept  bbbb", "kept  cccc")
  end

  it "refuses without confirm and removes nothing", :aggregate_failures do
    fleet
    out = launch("session_cleanup.remove_safe!", "run.value=s2", "--wait")

    expect(out).not_to include("cleaned")
    expect(removed).to be_empty
  end

  it "keeps a session whose transcript cannot be found" do
    list({ id: "zzzz", sessionId: "zzzz-lost", name: "lost", kind: "background", state: "done" })

    expect(launch("session_cleanup.removable")).to include("kept: its worktree cannot be found")
  end
end
