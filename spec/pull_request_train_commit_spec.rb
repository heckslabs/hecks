require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/git_train"

# The push train boards the commit a boarding names, not only the head of main: an older commit
# goes to its own train/ branch while the commits above it stay on local main. A boarding that
# names no commit boards the head. Against a local bare repository and a clone of it.
RSpec.describe "the push train boarding a named commit", :io do
  let(:scratch) { Dir.mktmpdir("hecks-pr-train-commit") }
  let(:work) { File.join(scratch, "work") }

  COMMIT_TRAIN_IDENTITY = { "GIT_AUTHOR_NAME" => "A", "GIT_AUTHOR_EMAIL" => "a@example.test",
                            "GIT_COMMITTER_NAME" => "A", "GIT_COMMITTER_EMAIL" => "a@example.test" }.freeze

  def git(*args, dir: work)
    out, err, status = Open3.capture3(COMMIT_TRAIN_IDENTITY, "git", *args, chdir: dir)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?

    out.strip
  end

  def commit(name)
    File.write(File.join(work, name), name)
    git("add", name)
    git("commit", "-q", "-m", name)
    git("rev-parse", "HEAD")
  end

  def github(argv, **)
    return [true, "https://github.test/heckslabs/hecks/pull/1\n"] if argv[1..2] == %w[pr create]
    return [false, "no pull request found"] if argv[1..2] == %w[pr view]

    [true, ""]
  end

  def still_mint = instance_double(Hecks::Adapters::GitTrain::MintStep, run: "the Hecks shape did not move")

  def carry(**held)
    Hecks::Adapters::GitTrain.new(mint: still_mint, runner: method(:github)).carry(checkout: { value: work }, **held)
  end

  def remote(ref) = git("ls-remote", "origin", ref).split.first

  def branch_for(sha) = Hecks::Adapters::GitTrain::PullRequestBoarding.branch_for(sha)

  before do
    git("init", "-q", "--bare", "-b", "main", "origin.git", dir: scratch)
    git("clone", "-q", "origin.git", work, dir: scratch)
    git("checkout", "-q", "-b", "main")
    commit("first")
    git("push", "-q", "origin", "main")
    @older = commit("second")
    @newer = commit("third")
  end

  after { FileUtils.remove_entry(scratch) }

  it "boards the named older commit and leaves the newer one on local main", :aggregate_failures do
    answer = carry(commit: { value: @older })

    expect(answer).to include(outcome: { value: "queued" }, boarded: { value: @older })
    expect(remote("refs/heads/#{branch_for(@older)}")).to eq(@older)
    expect(git("rev-parse", "main")).to eq(@newer)
  end

  it "names the newer commits that were not boarded" do
    expect(carry(commit: { value: @older })[:report][:value]).to include("1 commit(s) landed meanwhile")
  end

  it "boards the head when no commit is named" do
    expect(carry).to include(boarded: { value: @newer })
  end

  it "refuses a commit that is not on the branch, boarding nothing", :aggregate_failures do
    stray = "f" * 40

    expect { carry(commit: { value: stray }) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /not on main/)
    expect(remote("refs/heads/#{branch_for(stray)}")).to be_nil
  end
end
