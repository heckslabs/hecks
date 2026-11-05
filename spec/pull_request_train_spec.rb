require "spec_helper"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/git_train"

# The push train boards main as a pull request: the boarded commit goes to its own train/ branch,
# a PR into main is opened, and auto-merge is turned on. Main itself is never moved by the train.
# Against a local bare repository and a clone of it; `gh` is a fake that records what it was asked.
RSpec.describe "the push train boarding main as a pull request", :io do
  let(:scratch) { Dir.mktmpdir("hecks-pr-train") }
  let(:work) { File.join(scratch, "work") }
  let(:gh_calls) { [] }
  let(:gh_fails_on) { nil }
  let(:identity) do
    { "GIT_AUTHOR_NAME" => "A", "GIT_AUTHOR_EMAIL" => "a@example.test",
      "GIT_COMMITTER_NAME" => "A", "GIT_COMMITTER_EMAIL" => "a@example.test" }
  end

  def git(*args, dir: work)
    out, err, status = Open3.capture3(identity, "git", *args, chdir: dir)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?

    out.strip
  end

  def commit(name)
    File.write(File.join(work, name), name)
    git("add", name)
    git("commit", "-q", "-m", name)
  end

  # A fake `gh`: answers pr create with a URL and pr merge with success, unless told to fail.
  def github(argv, **)
    gh_calls << argv
    return [false, "boom"] if gh_fails_on && argv[1..2] == gh_fails_on

    return [true, "https://github.test/heckslabs/hecks/pull/1\n"] if argv[1..2] == %w[pr create]

    [true, ""]
  end

  def still_mint = instance_double(Hecks::Adapters::GitTrain::MintStep, run: "the Hecks shape did not move")

  def train = Hecks::Adapters::GitTrain.new(mint: still_mint, runner: method(:github))

  def carry = train.carry(checkout: { value: work })

  def remote(ref) = git("ls-remote", "origin", ref).split.first

  before do
    git("init", "-q", "--bare", "-b", "main", "origin.git", dir: scratch)
    git("clone", "-q", "origin.git", work, dir: scratch)
    git("checkout", "-q", "-b", "main")
    commit("first")
    git("push", "-q", "origin", "main")
  end

  after { FileUtils.remove_entry(scratch) }

  it "pushes the commit to its own branch, opens a PR, and turns on auto-merge", :aggregate_failures do
    commit("second")
    boarded = git("rev-parse", "main")
    branch = Hecks::Adapters::GitTrain::PullRequestBoarding.branch_for(boarded)

    expect(carry).to include(outcome: { value: "queued" }, boarded: { value: boarded })
    expect(remote("refs/heads/#{branch}")).to eq(boarded)
    expect(remote("refs/heads/main")).to eq(git("rev-parse", "main~1"))
    expect(gh_calls).to include(array_including("pr", "create"), array_including("pr", "merge", branch))
  end

  it "answers carried, opening no PR, when main already holds the commit", :aggregate_failures do
    expect(carry).to include(outcome: { value: "carried" })
    expect(gh_calls).to be_empty
  end

  context "when gh cannot open the PR" do
    let(:gh_fails_on) { %w[pr create] }

    it "refuses, and turns nothing on", :aggregate_failures do
      commit("second")

      expect { carry }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /could not open a PR/)
      expect(gh_calls.map { |argv| argv[1..2] }).not_to include(%w[pr merge])
    end
  end
end
