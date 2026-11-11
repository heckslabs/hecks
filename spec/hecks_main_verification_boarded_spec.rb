require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/main_verification"

# A verification runs the quick gate and nothing else, and it settles when a train pull request
# holds the commit, whoever boarded it: superseded, with no further check. The repositories are
# throwaway ones on a local bare remote; the checks and `gh` are fakes.
RSpec.describe Hecks::Adapters::MainVerification, "#check on a boarded commit" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-main-boarded")) }
  let(:ran) { [] }
  let(:pull_requests) { {} }
  let(:while_running) { [] }

  before do
    git("init", "-q", "--bare", "-b", "main", File.join(dir, "remote.git"), chdir: dir)
    git("clone", "-q", File.join(dir, "remote.git"), repo, chdir: dir)
    git("checkout", "-q", "-B", "main")
    commit("README")
    git("push", "-q", "origin", "main")
    described_class.runner = method(:fake_run)
    Hecks::Adapters::MainIntegration::BoardedCheck.runner = method(:fake_gh)
    described_class.log_directory = File.join(dir, "logs")
  end

  after do
    described_class.runner = nil
    described_class.log_directory = nil
    Hecks::Adapters::MainIntegration::BoardedCheck.runner = nil
    FileUtils.remove_entry(dir)
  end

  def fake_run(argv, chdir:)
    ran << argv.drop(3).first(2).join(" ")
    while_running.each(&:call)
    [true, chdir && ""]
  end

  def fake_gh(argv, chdir:)
    [true, "#{pull_requests.fetch(argv[3], "NONE")}\n#{chdir && ""}".strip]
  end

  def repo = File.join(dir, "repo")

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out.strip
  end

  def commit(file)
    File.write(File.join(repo, file), file)
    git("add", ".")
    git("commit", "-q", "-m", file)
    git("rev-parse", "main")
  end

  # What the train leaves on origin for a boarding: the branch named for the boarded commit.
  def board(sha, state: "OPEN")
    branch = "train/main-#{sha[0, 12]}"
    git("push", "-q", "origin", "#{sha}:refs/heads/#{branch}")
    pull_requests[branch] = state
  end

  def outcome(landed) = described_class.new.check(landed: landed, checkout: repo)[:outcome][:value]

  it "runs the quick gate and no spec run", :aggregate_failures do
    expect(outcome(commit("a.txt"))).to eq("verified")
    expect(ran).to eq(["gate_run.gate! stage=quick"])
  end

  it "answers superseded without a check when a train pull request is open for the commit", :aggregate_failures do
    landed = commit("a.txt")
    board(landed)
    expect(outcome(landed)).to eq("superseded")
    expect(ran).to be_empty
  end

  it "settles a commit whose descendant was boarded" do
    landed = commit("a.txt")
    board(commit("b.txt"))
    expect(outcome(landed)).to eq("superseded")
  end

  it "does not answer verified when the boarding comes during the gate", :aggregate_failures do
    landed = commit("a.txt")
    while_running << -> { board(landed) }
    expect(outcome(landed)).to eq("superseded")
    expect(ran).to eq(["gate_run.gate! stage=quick"])
  end

  it "verifies a commit whose train pull request was closed" do
    landed = commit("a.txt")
    board(landed, state: "CLOSED")
    expect(outcome(landed)).to eq("verified")
  end

  it "verifies a commit when the train branch is of an unrelated commit" do
    older = git("rev-parse", "main")
    board(older)
    expect(outcome(commit("a.txt"))).to eq("verified")
  end
end
