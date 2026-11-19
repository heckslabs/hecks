require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/main_verification"
require_relative "support/hecks_launcher_stub"

# An advance stops verifying a commit `origin/main` already carries: it answers `superseded`
# without a check, and one `origin/main` does not carry is still verified. The repositories are
# throwaway ones on a local bare remote and the checks are a fake runner.
RSpec.describe Hecks::Adapters::MainVerification, "#check" do
  let(:dir) { File.realpath(Dir.mktmpdir("hecks-main-carried")) }
  let(:ran) { [] }

  before do
    git("init", "-q", "--bare", "-b", "main", File.join(dir, "remote.git"), chdir: dir)
    git("clone", "-q", File.join(dir, "remote.git"), repo, chdir: dir)
    git("checkout", "-q", "-B", "main")
    HecksLauncherStub.place(repo)
    commit(repo, "README")
    git("push", "-q", "origin", "main")
    checks = instance_double(Hecks::Adapters::MainIntegration::Checks, all: [["one", %w[one]], ["two", %w[two]]])
    allow(Hecks::Adapters::MainIntegration::Checks).to receive(:new).and_return(checks)
    described_class.runner = method(:fake_run)
    described_class.log_directory = File.join(Dir.tmpdir, "hecks-carried-logs-#{Process.pid}")
  end

  def fake_run(argv, chdir:)
    ran << argv.first
    [true, chdir && ""]
  end

  after do
    described_class.runner = nil
    FileUtils.rm_rf(described_class.log_directory)
    described_class.log_directory = nil
    FileUtils.remove_entry(dir)
  end

  def repo = File.join(dir, "repo")

  def git(*args, chdir: repo)
    out, status = Open3.capture2e("git", "-c", "user.name=t", "-c", "user.email=t@t", *args, chdir: chdir)
    raise out unless status.success?

    out.strip
  end

  def commit(where, file)
    File.write(File.join(where, file), file)
    git("add", ".", chdir: where)
    git("commit", "-q", "-m", file, chdir: where)
  end

  def landed_commit
    commit(repo, "a.txt")
    git("rev-parse", "main")
  end

  def advance(landed) = described_class.new.check(landed: landed, checkout: repo)

  def outcome(answer) = answer[:outcome][:value]

  def report(answer) = answer[:report][:value]

  # The origin moves on beside the boarded commit, then lands the train: as a merge commit that
  # keeps the boarded sha, or (`squash: true`) as one commit of the same tree titled for it.
  def train_at_origin(boarded, squash: false)
    other = File.join(dir, "other")
    git("clone", "-q", File.join(dir, "remote.git"), other, chdir: dir)
    commit(other, squash ? "a.txt" : "elsewhere.txt")
    git("commit", "-q", "--amend", "-m", "Train: main at #{boarded[0, 9]} (#1)", chdir: other) if squash
    git("fetch", "-q", repo, "main", chdir: other)
    git("merge", "-q", "--no-ff", "-m", "Merge pull request #1", "FETCH_HEAD", chdir: other) unless squash
    git("push", "-q", "origin", "main", chdir: other)
  end

  it "answers superseded without a check when origin/main contains the commit", :aggregate_failures do
    landed = landed_commit
    git("push", "-q", "origin", "main")
    expect(outcome(advance(landed))).to eq("superseded")
    expect(ran).to be_empty
  end

  it "answers superseded without a check when a train's merge commit carries the commit", :aggregate_failures do
    landed = landed_commit
    train_at_origin(landed)
    answer = advance(landed)
    expect([outcome(answer), ran]).to eq(["superseded", []])
    expect(report(answer)).to include("is contained in origin/main")
  end

  it "verifies a commit that only a squash on origin/main names, since nothing squashes" do
    landed = landed_commit
    train_at_origin(landed, squash: true)
    expect(outcome(advance(landed))).to eq("verified")
  end

  it "verifies a commit origin/main does not carry", :aggregate_failures do
    landed = landed_commit
    expect(outcome(advance(landed))).to eq("verified")
    expect(ran).to eq(%w[one two])
  end
end
