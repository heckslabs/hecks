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

  def carry = described_class.new.carry(checkout: { value: work })

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
    described_class.new.carry(checkout: { value: work }, **args)
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
end
