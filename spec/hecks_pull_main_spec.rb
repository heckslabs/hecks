require "spec_helper"
require "tmpdir"
require "open3"
require "hecks/hecks/adapters/git_landing"
require "hecks/hecks/adapters/git_worktree_add"

# Pulling main first: the adapter operation, and the commands that lean on it. Every example builds
# a throwaway repository with a local bare remote, so nothing reaches a network.
RSpec.describe "pulling main first" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-pull-main")) }
  let(:adder) { Hecks::Adapters::GitWorktreeAdd.new }
  let(:lander) { Hecks::Adapters::GitLanding.new }

  after { FileUtils.remove_entry(dir) }

  def remote = File.join(dir, "remote.git")

  def repo = File.join(dir, "repo")

  def other = File.join(dir, "other")

  def failure = Hecks::Adapters::ConsoleCapture::Failure

  def completed_gate = ->(_) { Hecks::Adapters::Shell::Result.new('{"status": "completed"}', "", ok) }

  def ok = instance_double(Process::Status, success?: true)

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out.strip
  end

  # The code under test commits too (a rebase), so each repo carries its own identity.
  def identify(where)
    git("config", "user.name", "t", chdir: where)
    git("config", "user.email", "t@t", chdir: where)
  end

  def commit(where, file)
    File.write(File.join(where, file), file)
    git("add", ".", chdir: where)
    git("commit", "-m", file, chdir: where)
  end

  # origin has one commit; `repo` and `other` are clones of it.
  before do
    git("init", "--bare", "-b", "main", remote, chdir: dir)
    git("clone", remote, repo, chdir: dir)
    git("checkout", "-b", "main", chdir: repo) unless git("branch", "--show-current") == "main"
    commit(repo, "README")
    git("push", "origin", "main")
    git("clone", remote, other, chdir: dir)
    [repo, other].each { |where| identify(where) }
  end

  # Another session pushes a commit to origin/main.
  def origin_moves(file = "theirs.txt")
    commit(other, file)
    git("push", "origin", "main", chdir: other)
  end

  def tip(ref, where = repo) = git("rev-parse", ref, chdir: where)

  describe "LinkedTree.Add" do
    it "fast-forwards a main that is behind before cutting the branch", :aggregate_failures do
      origin_moves
      tree = File.join(repo, ".claude", "worktrees", "work-a")
      adder.create(checkout: repo, branch: "work-a")
      expect(File).to exist(File.join(tree, "theirs.txt"))
      expect(tip("main")).to eq(tip("origin/main"))
    end

    it "rebases a diverged main and loses no commit", :aggregate_failures do
      commit(repo, "mine.txt")
      origin_moves
      adder.create(checkout: repo, branch: "work-b")
      expect(git("ls-tree", "-r", "--name-only", "work-b").split("\n")).to include("mine.txt", "theirs.txt")
      expect(git("merge-base", "--is-ancestor", "origin/main", "main")).to eq("")
    end

    it "refuses by name when the checkout has uncommitted changes", :aggregate_failures do
      origin_moves
      File.write(File.join(repo, "README"), "edited")
      expect { adder.create(checkout: repo, branch: "work-c") }
        .to raise_error(failure, "cannot pull main: the checkout has uncommitted changes")
      expect(git("branch", "--list", "work-c")).to eq("")
    end

    it "refuses by name in the middle of a rebase" do
      origin_moves
      FileUtils.mkdir_p(File.join(repo, ".git", "rebase-merge"))
      expect { adder.create(checkout: repo, branch: "work-d") }
        .to raise_error(failure, "cannot pull main: the checkout is in the middle of a rebase")
    end
  end

  describe "LinkedTree.PullMain" do
    it "is idempotent" do
      origin_moves
      adder.pull(checkout: repo)
      expect(adder.pull(checkout: repo)[:report][:value]).to include("up to date")
    end
  end

  describe "LinkedTree.PullMain with main checked out nowhere" do
    def report = adder.pull(checkout: repo)[:report][:value]

    # Local main takes `file` as an unpushed commit, then the checkout moves to another branch.
    def mine_then_leave(file)
      commit(repo, file)
      git("checkout", "-b", "elsewhere")
    end

    it "carries a main whose tree origin/main already holds, naming the squash", :aggregate_failures do
      mine_then_leave("mine.txt")
      push_from_other("mine.txt", "squash of mine", "mine.txt")
      expect(report).to start_with("main carried by squash")
      expect(tip("main")).to eq(tip("origin/main"))
    end

    it "fast-forwards the ref when main is only behind", :aggregate_failures do
      git("checkout", "-b", "elsewhere")
      origin_moves
      expect(report).to start_with("main fast-forwarded 1 commit")
      expect(tip("main")).to eq(tip("origin/main"))
    end

    it "rebases a truly diverged main in a temporary worktree and loses no commit", :aggregate_failures do
      mine_then_leave("mine.txt")
      origin_moves
      expect(report).to include("checked out nowhere")
      expect(git("ls-tree", "-r", "--name-only", "main").split("\n")).to include("mine.txt", "theirs.txt")
      expect(git("worktree", "list").lines.size).to eq(1)
    end

    def push_from_other(file, message, content)
      File.write(File.join(other, file), content)
      git("add", ".", chdir: other)
      git("commit", "-m", message, chdir: other)
      git("push", "origin", "main", chdir: other)
    end

    def clash_on_origin = push_from_other("clash.txt", "clash", "theirs")

    it "refuses on conflict and leaves main where it was", :aggregate_failures do
      mine_then_leave("clash.txt")
      clash_on_origin
      expect { adder.pull(checkout: repo) }.to raise_error(failure, /cannot pull main: .*conflicts in clash.txt/)
      expect(git("worktree", "list").lines.size).to eq(1)
    end
  end

  describe "Landing" do
    def stale_branch
      git("worktree", "add", "-b", "work/stale", File.join(dir, "stale"), "main")
      commit(File.join(dir, "stale"), "stale.txt")
      origin_moves
    end

    it "refuses a branch whose base is behind origin/main, naming the fix" do
      stale_branch
      expect { lander.merge(checkout: repo, branch: "work/stale") }
        .to raise_error(failure, "work/stale lacks 1 commit that origin/main has: pull main first " \
                                 "(LinkedTree.pull_main!) and rebase the branch onto it")
    end

    it "accepts the branch after the pull and rebase" do
      stale_branch
      adder.pull(checkout: repo)
      git("rebase", "main", chdir: File.join(dir, "stale"))
      expect(lander.merge(checkout: repo, branch: "work/stale")[:outcome][:value]).to eq("fast_forwarded")
    end

    it "pulls main first when it finishes", :aggregate_failures do
      stale_branch
      lander.finish_branch(checkout: File.join(dir, "stale"), branch: "work/stale", gate: completed_gate)
      expect(git("log", "--format=%s", "main")).to include("theirs.txt", "stale.txt")
      expect(tip("main")).not_to eq(tip("origin/main"))
    end
  end

  describe "the Brief" do
    it "states the step and no hand-typed worktree add from main", :aggregate_failures do
      text = File.read(File.expand_path("../lib/hecks/coder/coder.bluebook", __dir__))
      workflow = text.lines.grep(/sets :workflow/).join
      expect(workflow).to include("Pull main first, always", "LinkedTree.add!")
      expect(workflow).not_to match(/git worktree add .* main/)
    end
  end
end
