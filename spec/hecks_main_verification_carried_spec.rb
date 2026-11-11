require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/main_verification"

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

  # The origin merges the train as one commit titled for the boarded sha, with the same tree.
  def squash_at_origin(boarded)
    other = File.join(dir, "other")
    git("clone", "-q", File.join(dir, "remote.git"), other, chdir: dir)
    File.write(File.join(other, "a.txt"), "a.txt")
    git("add", ".", chdir: other)
    git("commit", "-q", "-m", "Train: main at #{boarded[0, 9]} (#1)", chdir: other)
    git("push", "-q", "origin", "main", chdir: other)
  end

  it "answers superseded without a check when origin/main contains the commit", :aggregate_failures do
    landed = landed_commit
    git("push", "-q", "origin", "main")
    expect(outcome(advance(landed))).to eq("superseded")
    expect(ran).to be_empty
  end

  it "answers superseded, carried by squash, when a train squash holds the commit", :aggregate_failures do
    landed = landed_commit
    squash_at_origin(landed)
    answer = advance(landed)
    expect(outcome(answer)).to eq("superseded")
    expect(report(answer)).to include("carried by squash")
  end

  it "does not run a check after the squash is seen" do
    landed = landed_commit
    squash_at_origin(landed)
    advance(landed)
    expect(ran).to be_empty
  end

  it "verifies a commit origin/main does not carry", :aggregate_failures do
    landed = landed_commit
    expect(outcome(advance(landed))).to eq("verified")
    expect(ran).to eq(%w[one two])
  end
end
