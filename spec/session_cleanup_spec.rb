require "spec_helper"
require "support/stand_in_claude"
require "fileutils"
require "json"
require "open3"

# `SessionCleanup.Removable` and `SessionCleanup.RemoveSafe` through the booted Hecks domain. The
# stand-in `claude` lists the sessions and records each `rm` in a log, `HOME` points at a scratch
# directory holding the transcripts, and the worktrees are throwaway git clones, so no real session
# is listed or removed. The AgentRun ledger is a stand-in: each session but `hhhh` has a run, and
# only a run `finished` with condition `done` makes its session a candidate.
RSpec.describe "SessionCleanup through the Cleaning port" do
  include_context "with a stand-in claude"

  before(:all) do
    @hecks = boot_hecks_in_memory
  end

  before do
    allow(Hecks::Adapters::Dispatching::WorkItems).to(receive(:new).and_wrap_original do |original, *args|
      original.call(*args).tap { |reader| stand_in_ledger(reader) }
    end)
  end

  # The run each listed session belongs to, with the run's status and condition.
  def ledger
    { "aaaa-clean" => %w[finished done], "bbbb-dirty" => %w[finished done], "cccc-ahead" => %w[finished done],
      "dddd-gone" => %w[finished done], "eeee-none" => %w[finished done], "ffff-work" => %w[started],
      "gggg-wait" => %w[started], "iiii-halt" => %w[finished stopped], "zzzz-lost" => %w[finished done] }
  end

  # What the fleet's listing must say: the safe sessions and each kept one's reason.
  def judged
    ["aaaa  run r-aaaa n-aaaa  safe", "dddd  run r-dddd n-dddd  safe", "eeee  run r-eeee n-eeee  safe",
     "uncommitted", "origin lacks", "its run r-ffff is started", "its run r-gggg is started",
     "hhhh  plain n-hhhh  kept: no dispatched run holds it", "its run r-iiii is finished stopped"]
  end

  def stand_in_ledger(reader)
    runs = ledger.to_h { |id, (status, condition)| ["r-#{id[0, 4]}", { status: status, condition: condition.to_s }] }
    allow(reader).to receive_messages(run_sessions: ledger.to_h { |id, _| [id, "r-#{id[0, 4]}"] }, runs: runs)
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
         session("cccc-ahead", "done", worktree("ahead", :ahead)), session("dddd-gone", "done", File.join(scratch, "gone")),
         session("eeee-none", "done", :none), session("ffff-work", "working", :none), session("gggg-wait", "blocked", :none),
         session("hhhh-plain", "done", :none), session("iiii-halt", "done", :none))
  end

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks").first.to_s

  def removed = File.exist?(File.join(scratch, "rm.log")) ? File.readlines(File.join(scratch, "rm.log"), chomp: true) : []

  it "marks each session safe or kept with the reason, and removes nothing", :aggregate_failures do
    fleet
    out = launch("session_cleanup.removable")

    expect(out).to include(*judged)
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

  it "keeps a session whose transcript cannot be read, as one a person may have spoken in" do
    list({ id: "zzzz", sessionId: "zzzz-lost", name: "lost", kind: "background", state: "done" })

    expect(launch("session_cleanup.removable")).to include("zzzz  run r-zzzz lost  kept: a person spoke in it")
  end
end
