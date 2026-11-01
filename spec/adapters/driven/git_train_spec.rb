require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/git_train"

# The Train port's adapter, against a local bare repository and clones of it: a boarding pushes the
# local branch, rides on an earlier push, merges a remote that moved, and refuses what it cannot
# push.
RSpec.describe Hecks::Adapters::GitTrain, :io do
  let(:scratch) { Dir.mktmpdir("hecks-git-train") }
  let(:work) { File.join(scratch, "work") }
  let(:identity) do
    { "GIT_AUTHOR_NAME" => "A", "GIT_AUTHOR_EMAIL" => "a@example.test",
      "GIT_COMMITTER_NAME" => "A", "GIT_COMMITTER_EMAIL" => "a@example.test" }
  end

  def git(*args, dir: work)
    out, err, status = Open3.capture3(identity, "git", *args, chdir: dir)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?

    out.strip
  end

  def commit(name, dir: work, text: name)
    File.write(File.join(dir, name), text)
    git("add", name, dir: dir)
    git("commit", "-q", "-m", name, dir: dir)
  end

  # A second clone that pushes on its own, as another machine would.
  def push_elsewhere(name, text: name)
    other = File.join(scratch, "other")
    git("clone", "-q", "-b", "main", File.join(scratch, "origin.git"), other, dir: scratch) unless File.directory?(other)
    commit(name, dir: other, text: text)
    git("push", "-q", "origin", "main", dir: other)
  end

  def refuse_pushes
    hooks = File.join(scratch, "hooks")
    FileUtils.mkdir_p(hooks)
    File.write(File.join(hooks, "pre-push"), "#!/bin/sh\necho the suite is red >&2\nexit 1\n")
    FileUtils.chmod("+x", File.join(hooks, "pre-push"))
    git("config", "core.hooksPath", hooks)
  end

  # The Hecks mint a boarding runs first, answering that the shape did not move.
  def still_mint = instance_double(described_class::MintStep, run: "the Hecks shape f30dcb did not move")

  def train = described_class.new(mint: still_mint)

  def carry = train.carry(checkout: { value: work })

  before do
    git("init", "-q", "--bare", "-b", "main", "origin.git", dir: scratch)
    git("clone", "-q", "origin.git", work, dir: scratch)
    git("checkout", "-q", "-b", "main")
    git("config", "user.name", "A")
    git("config", "user.email", "a@example.test")
    commit("first")
    git("push", "-q", "origin", "main")
  end

  after { FileUtils.remove_entry(scratch) }

  # A pre-push hook that records the git configuration the repository's real hook reads to pick its
  # stage.
  def record_gate_config
    hooks = File.join(scratch, "hooks")
    FileUtils.mkdir_p(hooks)
    hook = File.join(hooks, "pre-push")
    recorded = File.join(scratch, "gate")
    File.write(hook, "#!/bin/sh\nprintf '%s' \"$(git config --type=bool --get hecks.fullGate)\" > #{recorded}\n")
    FileUtils.chmod("+x", hook)
    git("config", "core.hooksPath", hooks)
  end

  # What the recording hook saw after a boarding of one new commit.
  def gate_config_after(commit_name, **args)
    commit(commit_name)
    train.carry(checkout: { value: work }, **args)
    File.read(File.join(scratch, "gate"))
  end

  it "leaves the pre-push hook its default gate when the boarding does not ask" do
    record_gate_config

    expect(gate_config_after("second")).to eq("")
  end

  it "hands the pre-push hook the whole gate when the boarding asks for it" do
    record_gate_config

    expect(gate_config_after("third", full_gate: { value: true })).to eq("true")
  end

  it "pushes the local branch and says how many commits went out", :aggregate_failures do
    commit("second")

    expect(carry).to include(outcome: { value: "pushed" }, pushed: { value: git("rev-parse", "main") })
    expect(git("rev-parse", "origin/main")).to eq(git("rev-parse", "main"))
  end

  it "rides on an earlier push that already carried the boarded commit" do
    expect(carry).to include(outcome: { value: "carried" }, boarded: { value: git("rev-parse", "main") })
  end

  # A pre-push hook that, on its first run only, lands a commit on the local branch the way another
  # session does while the gate runs.
  def land_during_first_push
    hooks = File.join(scratch, "hooks")
    FileUtils.mkdir_p(hooks)
    hook = File.join(hooks, "pre-push")
    File.write(hook, "#!/bin/sh\nunset GIT_DIR GIT_WORK_TREE\n[ -e #{scratch}/seen ] && exit 0\ntouch #{scratch}/seen\n" \
                     "git -C #{work} commit -q --allow-empty -m landed\n")
    FileUtils.chmod("+x", hook)
    git("config", "core.hooksPath", hooks)
  end

  def carriage = described_class::Carriage.new(Hecks::Adapters::Git.new, work, branch: "main", remote: "origin")

  it "refuses a branch that moved on after boarding, and pushes nothing", :aggregate_failures do
    boarded = git("rev-parse", "main")
    commit("newer")

    expect { carriage.carry(boarded) }
      .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /main moved since boarding.*board again/)
    expect(git("rev-parse", "origin/main")).to eq(boarded)
  end

  it "pushes exactly the boarded commit by its id", :aggregate_failures do
    commit("second")
    boarded = git("rev-parse", "main")

    expect(carriage.carry(boarded)).to include(outcome: { value: "pushed" }, pushed: { value: boarded })
    expect(git("rev-parse", "origin/main")).to eq(boarded)
  end

  it "leaves commits that landed while the gate ran unpushed, and names them", :aggregate_failures do
    commit("second")
    boarded = git("rev-parse", "main")
    land_during_first_push

    expect(carry).to include(pushed: { value: boarded }, report: { value: /1 commit\(s\) landed meanwhile and were not pushed/ })
    expect(git("rev-parse", "origin/main")).to eq(boarded)
  end

  # A mint that lands a commit on the branch after the boarding named its commit.
  def moving_mint
    instance_double(described_class::MintStep).tap do |mint|
      allow(mint).to receive(:run) do
        git("commit", "-q", "--allow-empty", "-m", "late")
        "minted"
      end
    end
  end

  it "refuses when the branch moves between boarding and the carry, naming the boarded commit", :aggregate_failures do
    commit("second")
    boarded = git("rev-parse", "main")
    attempt = -> { described_class.new(mint: moving_mint).carry(checkout: { value: work }) }

    expect(&attempt).to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /moved since boarding \(boarded #{boarded[0, 9]}/)
    expect(git("rev-parse", "origin/main")).not_to eq(git("rev-parse", "main"))
  end

  it "reports the boarded and pushed commits by name", :aggregate_failures do
    commit("second")
    head = git("rev-parse", "main")
    answer = carry

    expect(answer).to include(boarded: { value: head }, pushed: { value: head })
    expect(answer[:report][:value]).to include("boarded #{head[0, 9]}")
  end

  describe "the train's own shape" do
    let(:domain) { File.join(work, "lib", "hecks", "hecks") }

    before do
      FileUtils.mkdir_p(domain)
      File.write(File.join(domain, "a.bluebook"), "one")
      git("add", ".")
      git("commit", "-q", "-m", "domain")
      git("push", "-q", "origin", "main")
      git("checkout", "-q", "--detach")
      git("checkout", "-q", "-B", "main")
    end

    def train_at_domain
      described_class.new(mint: still_mint, domain: File.join(scratch, "train", "lib", "hecks", "hecks"))
    end

    def newer_shape
      File.write(File.join(domain, "a.bluebook"), "two")
      git("commit", "-q", "-am", "reshape")
    end

    def train_worktree = git("worktree", "add", "-q", "--detach", File.join(scratch, "train"), git("rev-parse", "main"))

    it "refuses when the running train lacks the boarded commit's bluebooks, pushing nothing", :aggregate_failures do
      train_worktree
      newer_shape

      expect { train_at_domain.carry(checkout: { value: work }) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /the train is not at the boarded commit: refresh it first/)
      expect(git("rev-parse", "origin/main")).not_to eq(git("rev-parse", "main"))
    end

    it "passes when the train holds the same bluebooks" do
      train_worktree
      commit("code-only")

      expect(train_at_domain.carry(checkout: { value: work })[:outcome]).to eq(value: "pushed")
    end
  end

  it "merges a remote that moved and brings the checked-out branch forward", :aggregate_failures do
    commit("mine")
    push_elsewhere("theirs")

    expect(carry[:outcome]).to eq(value: "pushed")
    expect(File).to exist(File.join(work, "theirs"))
  end

  it "refuses a branch that conflicts with the remote's, naming the file" do
    commit("shared", text: "mine")
    push_elsewhere("shared", text: "theirs")

    expect { carry }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /conflict in shared/)
  end

  it "refuses a push its pre-push hook turned away, with what the hook said" do
    commit("second")
    refuse_pushes

    expect { carry }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /the suite is red/)
  end

  it "opens the report with what the Hecks mint did" do
    commit("second")

    expect(carry[:report][:value]).to start_with("the Hecks shape f30dcb did not move, then boarded").and include("pushed")
  end

  # A mint that refuses, as `HeldMint#answer` does, with its reason.
  def refusing_mint
    held = Object.new
    def held.answer(**) = raise(Hecks::Runtime::WiringError, "the decision is needs_edge, not would_mint")
    described_class::MintStep.new(mint: held)
  end

  it "refuses with the mint's reason and pushes nothing when the mint refuses", :aggregate_failures do
    commit("second")
    attempt = -> { described_class.new(mint: refusing_mint).carry(checkout: { value: work }) }

    expect(&attempt).to raise_error(Hecks::Runtime::WiringError, /Hecks mint refused.*needs_edge/)
    expect(git("rev-parse", "origin/main")).not_to eq(git("rev-parse", "main"))
  end
end
