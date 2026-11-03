require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "timeout"
require "hecks/hecks/adapters/git_train"
require "hecks/hecks/adapters/git_landing/lineup"

# The push is made from a throwaway detached worktree at the boarded commit, so nothing that
# happens to the primary checkout (a landing, an edit) reaches the gate or the push. Temp
# repositories and a local bare remote; the pre-push hook is a script that records what it saw.
RSpec.describe Hecks::Adapters::GitTrain, :io do
  let(:scratch) { Dir.mktmpdir("hecks-isolated-push") }
  let(:work) { File.join(scratch, "work") }
  let(:seen) { File.join(scratch, "seen") }
  let(:identity) do
    { "GIT_AUTHOR_NAME" => "A", "GIT_AUTHOR_EMAIL" => "a@example.test",
      "GIT_COMMITTER_NAME" => "A", "GIT_COMMITTER_EMAIL" => "a@example.test" }
  end

  def git(*args, dir: work)
    out, err, status = Open3.capture3(identity, "git", *args, chdir: dir)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?

    out.strip
  end

  def commit(name, text: name)
    File.write(File.join(work, name), text)
    git("add", name)
    git("commit", "-q", "-m", name)
  end

  # Installs a pre-push hook; `body` runs in the worktree git pushes from.
  def hook(body)
    hooks = File.join(scratch, "hooks")
    FileUtils.mkdir_p(hooks)
    File.write(File.join(hooks, "pre-push"), "#!/bin/sh\nunset GIT_DIR GIT_WORK_TREE\n#{body}\n")
    FileUtils.chmod("+x", File.join(hooks, "pre-push"))
    git("config", "core.hooksPath", hooks)
  end

  # A hook that tells the spec it is gating, through a fifo, and stays there until the spec answers.
  def park_hook
    %w[gating go].each { |name| File.mkfifo(File.join(scratch, name)) }
    hook("echo > #{scratch}/gating\nread _ < #{scratch}/go")
  end

  def board = Thread.new { carry }.tap { through_fifo { File.read(File.join(scratch, "gating")) } }

  def release = through_fifo { File.write(File.join(scratch, "go"), "go\n") }

  # A fifo's open is a system call a child's exit can interrupt.
  def through_fifo
    yield
  rescue Errno::EINTR
    retry
  end

  def land_through_the_line
    Timeout.timeout(5) do
      Hecks::Adapters::GitLanding::Lineup.new(File.join(work, ".git"), locks: [], say: ->(_) {})
                                         .stand("work/a", onto: "main", checkout: work) { |_| commit("landed") && :landed }
    end
  end

  def remote_moves_on
    other = File.join(scratch, "other")
    git("clone", "-q", "-b", "main", File.join(scratch, "origin.git"), other, dir: scratch)
    File.write(File.join(other, "theirs"), "theirs")
    git("add", "theirs", dir: other)
    git("commit", "-q", "-m", "theirs", dir: other)
    git("push", "-q", "origin", "main", dir: other)
  end

  def carriage = described_class::Carriage.new(Hecks::Adapters::Git.new, work, branch: "main", remote: "origin")

  def failure = Hecks::Adapters::ConsoleCapture::Failure

  def mint = instance_double(described_class::MintStep, run: "the shape did not move")

  def carry = described_class.new(mint: mint).carry(checkout: { value: work })

  def pushed_from = File.read(seen).lines.first.strip

  before do
    git("init", "-q", "--bare", "-b", "main", "origin.git", dir: scratch)
    git("clone", "-q", "origin.git", work, dir: scratch)
    git("checkout", "-q", "-b", "main")
    commit("tracked", text: "boarded")
    git("push", "-q", "origin", "main")
    commit("second")
  end

  after { FileUtils.remove_entry(scratch) }

  it "gates the boarded commit's tree, not edits made in the primary checkout after boarding", :aggregate_failures do
    hook("echo changed > #{work}/tracked\ncat tracked > #{seen}")
    boarded = git("rev-parse", "main")

    expect(carry).to include(pushed: { value: boarded })
    expect(File.read(seen).strip).to eq("boarded")
    expect(File.read(File.join(work, "tracked")).strip).to eq("changed")
  end

  # Boards, lands through the landing line while the hook gates, then lets the push finish.
  def land_while_pushing
    park_hook
    train = board
    landed = land_through_the_line
    release
    [landed, train.value]
  end

  # Boards twice at once; the second must wait while the first gates.
  def board_twice
    park_hook
    first = board
    second = Thread.new { carry }
    waited = second.join(0.5).nil?
    release
    [waited, first.value, second.value]
  end

  it "lets a landing through while the push runs, and pushes only the boarded commit", :aggregate_failures do
    boarded = git("rev-parse", "main")
    landed, answer = land_while_pushing

    expect(landed).to eq(:landed)
    expect(answer).to include(pushed: { value: boarded }, report: { value: /1 commit\(s\) landed meanwhile/ })
    expect(git("rev-parse", "origin/main")).to eq(boarded)
  end

  it "serializes two boards at once: the second waits, then finds its commit carried" do
    waited, first, second = board_twice

    expect([waited, first[:outcome], second[:outcome]]).to eq([true, { value: "pushed" }, { value: "carried" }])
  end

  it "refuses a commit the remote moved away from, by the diverged message, pushing nothing", :aggregate_failures do
    remote_moves_on

    expect { carriage.carry(git("rev-parse", "main")) }
      .to raise_error(failure, %r{origin/main moved since \h+ was settled: it is not built on it; board again})
    expect(git("log", "-1", "--format=%s", "origin/main")).to eq("theirs")
  end

  describe "the throwaway tree" do
    def trees = git("worktree", "list", "--porcelain").lines.grep(/\Aworktree /)

    it "is removed after a push", :aggregate_failures do
      hook("pwd > #{seen}")
      carry

      expect(pushed_from).not_to eq(File.realpath(work))
      expect(File.exist?(pushed_from)).to be(false)
      expect(trees.size).to eq(1)
    end

    it "is removed after a refused push", :aggregate_failures do
      hook("pwd > #{seen}\nexit 1")

      expect { carry }.to raise_error(failure, /refused/)
      expect(File.exist?(pushed_from)).to be(false)
      expect(trees.size).to eq(1)
    end
  end
end
