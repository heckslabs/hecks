require "spec_helper"
require "tmpdir"
require "open3"
require "hecks/hecks/adapters/git_landing"
require "hecks/hecks/adapters/git_worktree_add"

# A train squash-merged on origin: local main's commits up to the boarded sha are carried and only
# the ones after it are rebased. Every example builds throwaway repositories on a local bare remote.
RSpec.describe "pulling main after a squash-merged train" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-pull-squash")) }
  let(:adder) { Hecks::Adapters::GitWorktreeAdd.new }

  after { FileUtils.remove_entry(dir) }

  def repo = File.join(dir, "repo")

  def other = File.join(dir, "other")

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out.strip
  end

  def commit(where, file, content = file)
    File.write(File.join(where, file), content)
    git("add", ".", chdir: where)
    git("commit", "-m", file, chdir: where)
  end

  before do
    git("init", "--bare", "-b", "main", File.join(dir, "remote.git"), chdir: dir)
    git("clone", File.join(dir, "remote.git"), repo, chdir: dir)
    git("checkout", "-b", "main") unless git("branch", "--show-current") == "main"
    commit(repo, "README")
    git("push", "origin", "main")
    git("clone", File.join(dir, "remote.git"), other, chdir: dir)
  end

  # Local main takes a, b (boarded), the origin squashes them, and `later` lands locally afterwards.
  def board_and_squash(later)
    %w[a.txt b.txt].each { |file| commit(repo, file) }
    boarded = git("rev-parse", "HEAD")
    commit(repo, later, "mine")
    git("merge", "--ff-only", "origin/main", chdir: other)
    squash(boarded)
  end

  def squash(boarded)
    %w[a.txt b.txt].each { |file| File.write(File.join(other, file), file) }
    git("add", ".", chdir: other)
    git("commit", "-m", "Train: main at #{boarded[0, 9]} (#1)", chdir: other)
    git("push", "origin", "main", chdir: other)
  end

  def report = adder.pull(checkout: repo)[:report][:value]

  it "rebases only the commit after the boarded sha and names the carried range", :aggregate_failures do
    board_and_squash("later.txt")
    expect(report).to include("carried by squash: 2 commits", "rebased 1 after it")
    expect(git("log", "--format=%s", "origin/main..main")).to eq("later.txt")
    expect(git("status", "-sb").lines.first).to include("[ahead 1]")
  end

  # Both sides then change a.txt, so a commit after the boarded sha cannot replay cleanly.
  def diverge_on_a
    board_and_squash("later.txt")
    commit(repo, "a.txt", "mine")
    commit(other, "a.txt", "theirs")
    git("push", "origin", "main", chdir: other)
  end

  def refusal = /cannot pull main: .*conflicts in a.txt/

  it "refuses by name when the commit after the boarded sha conflicts", :aggregate_failures do
    diverge_on_a
    expect { report }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, refusal)
    expect(git("log", "--oneline", "origin/main..main").lines.size).to eq(4)
  end

  describe "landing.finish! of a branch cut from the boarded commit" do
    let(:lander) { Hecks::Adapters::GitLanding.new }

    def gate = ->(_) { Hecks::Adapters::Shell::Result.new('{"status": "completed"}', "", ok) }

    def ok = instance_double(Process::Status, success?: true)

    def branch_from_boarded
      git("worktree", "add", "-b", "work/x", File.join(dir, "x"), "main")
      commit(File.join(dir, "x"), "x.txt")
    end

    # main: README, a, b (boarded); the branch is cut there; origin squashes, then edits a.txt.
    def squashed_then_edited
      %w[a.txt b.txt].each { |file| commit(repo, file) }
      boarded = git("rev-parse", "HEAD")
      branch_from_boarded
      git("merge", "--ff-only", "origin/main", chdir: other)
      squash(boarded)
      commit(other, "a.txt", "theirs")
      git("push", "origin", "main", chdir: other)
    end

    it "replays only the branch's own commit onto main", :aggregate_failures do
      squashed_then_edited
      lander.finish_branch(checkout: File.join(dir, "x"), branch: "work/x", gate: gate)
      expect(git("log", "--format=%s", "origin/main..main")).to eq("x.txt")
      expect(git("show", "main:a.txt")).to eq("theirs")
    end
  end
end
