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

  IDENTITY = { "GIT_AUTHOR_NAME" => "A", "GIT_AUTHOR_EMAIL" => "a@example.test",
               "GIT_COMMITTER_NAME" => "A", "GIT_COMMITTER_EMAIL" => "a@example.test" }.freeze

  def git(*args, dir: work)
    out, err, status = Open3.capture3(IDENTITY, "git", *args, chdir: dir)
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
    return [false, "no pull request found"] if argv[1..2] == %w[pr view]

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

  def branch_for(commit) = Hecks::Adapters::GitTrain::PullRequestBoarding.branch_for(commit)

  it "pushes the commit to its own branch and leaves main where it was", :aggregate_failures do
    commit("second")
    boarded = git("rev-parse", "main")

    expect(carry).to include(outcome: { value: "queued" }, boarded: { value: boarded })
    expect(remote("refs/heads/#{branch_for(boarded)}")).to eq(boarded)
    expect(remote("refs/heads/main")).to eq(git("rev-parse", "main~1"))
  end

  it "opens a PR and turns on auto-merge for that branch" do
    commit("second")

    carry
    merged = array_including("pr", "merge", branch_for(git("rev-parse", "main")))
    expect(gh_calls).to include(array_including("pr", "create"), merged)
  end

  it "answers carried, opening no PR, when main already holds the commit", :aggregate_failures do
    expect(carry).to include(outcome: { value: "carried" })
    expect(gh_calls).to be_empty
  end

  describe "observing a queued boarding" do
    def boarded = "a" * 40

    def branch = Hecks::Adapters::GitTrain::PullRequestBoarding.branch_for(boarded)

    def observe(view)
      runner = ->(argv, **) { argv[1..2] == %w[pr view] ? view : [false, "unexpected"] }
      Hecks::Adapters::GitTrain::PullRequestBoarding::Observation.new(runner, work).answer(boarded)
    end

    it "answers open while the PR has not merged", :aggregate_failures do
      answer = observe([true, JSON.generate(state: "OPEN", mergeCommit: nil)])
      expect(answer[:outcome]).to eq({ value: "open" })
      expect(answer).not_to include(:pushed)
    end

    it "answers merged with the merge commit as the pushed commit", :aggregate_failures do
      merge = "b" * 40
      answer = observe([true, JSON.generate(state: "MERGED", mergeCommit: { oid: merge })])
      expect(answer).to include(outcome: { value: "merged" }, pushed: { value: merge })
      expect(answer[:report][:value]).to include(branch, merge[0, 9])
    end

    it "refuses a merged PR that names no merge commit" do
      expect { observe([true, JSON.generate(state: "MERGED", mergeCommit: nil)]) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /named no merge commit/)
    end

    it "refuses when gh cannot read the PR" do
      expect { observe([false, "no such PR"]) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /could not read the PR/)
    end
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
