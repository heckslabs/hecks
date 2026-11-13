# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"

# The stand-in `claude` of the reap specs: it lists the sessions in `sessions.json` and, for each
# `rm`, writes the session and whether the worktree named in `tree` still stood into `rm.log`, so a
# spec can see the order in which a worktree and its session went.
REAPING_CLAUDE = <<~SH
  #!/bin/sh
  here=$(dirname "$0")
  if [ "$1" = "agents" ]; then cat "$here/sessions.json"; exit 0; fi
  if [ "$1" = "rm" ]; then
    state=gone; [ -d "$(cat "$here/tree" 2>/dev/null)" ] && state=present
    echo "$2 tree=$state" >> "$here/rm.log"; exit 0
  fi
  if [ "$1" = "--agent" ] && [ "$2" = "hecks-probe-not-an-agent" ]; then printf 'Available agents: coder\\n'; exit 0; fi
  printf 'backgrounded · stand-in-session\\n'
SH

# Builds the fake world of a reap spec inside `scratch`: transcripts, a listing and worktrees.
module ReapingFleet
  FULL = "0000aaaa-1111-2222-3333-444455556666"

  def git(dir, *) = Open3.capture2e("git", "-C", dir, *)

  def install_claude
    path = File.join(scratch, "claude")
    File.write(path, REAPING_CLAUDE)
    File.chmod(0o755, path)
  end

  # A linked worktree on its own branch, already on `main`, holding only ignored scratch.
  def scratch_worktree
    base = File.join(scratch, "base")
    FileUtils.mkdir_p(base)
    seed(base)
    tree = File.join(scratch, "trees", "feature")
    git(base, "worktree", "add", "-q", "-b", "feature", tree)
    FileUtils.mkdir_p(File.join(tree, "tmp"))
    File.write(File.join(tree, "tmp", "a.log"), "x")
    File.write(File.join(scratch, "tree"), tree)
    tree
  end

  def seed(base)
    origin = File.join(scratch, "origin.git")
    Open3.capture2e("git", "init", "-q", "--bare", "-b", "main", origin)
    git(base, "init", "-q", "-b", "main")
    File.write(File.join(base, ".gitignore"), "tmp/\n")
    git(base, "add", ".")
    git(base, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "seed")
    git(base, "remote", "add", "origin", origin)
    git(base, "push", "-q", "origin", "main")
  end

  def transcript(entries, mtime: Time.now)
    dir = File.join(scratch, ".claude", "projects", "p")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "#{FULL}.jsonl")
    File.write(path, entries.map { |entry| JSON.generate(entry) }.join("\n"))
    File.utime(mtime, mtime, path)
  end

  def user(text) = { type: "user", message: { content: text } }
  def at_tree(path) = { type: "worktree-state", worktreeSession: { worktreePath: path } }

  def listing(id, state, name: "n", status: nil)
    entry = { id: id, sessionId: FULL, name: name, kind: "background", state: state, status: status }.compact
    File.write(File.join(scratch, "sessions.json"), JSON.generate([entry]))
  end

  def removed = File.exist?(File.join(scratch, "rm.log")) ? File.readlines(File.join(scratch, "rm.log"), chomp: true) : []

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks").first.to_s
  def reap = JSON.parse(launch("session_cleanup.reap!", "run.value=r1", "--wait")).dig("state", "report").to_s

  def finished_run(run)
    launch("agent_run.dispatch!", "run.value=#{run}", "repo.value=#{scratch}", "brief.value=go", "--wait")
    FileUtils.mkdir_p(File.join(scratch, "jobs", "stand-in-session"))
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state: "done"))
    launch("agent_run.check!", "to=#{run}", "--wait")
  end

  def done_run(*entries, tree: nil, listed: ["done", nil])
    transcript([user("go"), *entries, *(tree ? [at_tree(tree)] : [])])
    listing("stand-in-session", listed.first, status: listed.last)
    finished_run("r-done")
  end

  # A run that finished done whose session `claude agents` does not list: removed elsewhere.
  def gone_run
    transcript([user("go")])
    File.write(File.join(scratch, "sessions.json"), "[]")
    finished_run("r-done")
  end

  def plain_session(age_hours, tree: nil)
    transcript([user("hello"), *(tree ? [at_tree(tree)] : [])], mtime: now - (age_hours * 3600))
    listing("plain-1", "done", name: "chat")
  end
end

# A booted Hecks domain, a stand-in `claude` first on the path, `HOME` in `scratch` and a clock
# fixed at `now`, so a reap spec lists, removes and retires nothing real.
RSpec.shared_context "with a reaping fleet" do
  include ReapingFleet

  before { @hecks = boot_hecks_in_memory }

  let(:scratch) { File.realpath(Dir.mktmpdir("reaping")) }
  let(:now) { Time.utc(2026, 11, 11, 12) }

  around do |example|
    env = ENV.to_h.slice("PATH", "HOME")
    install_claude
    ENV["PATH"] = "#{scratch}:#{env["PATH"]}"
    ENV["HOME"] = scratch
    example.run
  ensure
    ENV.update(env)
    FileUtils.rm_rf(scratch)
  end

  before do
    allow(Hecks::Adapters::ClaudeAgents).to(receive(:new).and_wrap_original do |original, **context|
      original.call(**context, settings: { jobs: File.join(scratch, "jobs"), settle: 0 })
    end)
    allow(Hecks::Adapters::ClaudeCleaning).to(receive(:new).and_wrap_original do |original, **context|
      original.call(**context, settings: { now: -> { now } })
    end)
  end
end
