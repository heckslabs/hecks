require "spec_helper"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/git_train"

# A second train boards while the first is still in CI: stacked on the open train's head, its own
# pull request into main, and refused by name at two trains in flight. Against a local bare
# repository and a clone of it; `gh` is a stub that lists the open train pull requests it is given.
RSpec.describe "the push train stacking a second boarding on an open train", :io do
  let(:scratch) { Dir.mktmpdir("hecks-stacked-train") }
  let(:work) { File.join(scratch, "work") }
  let(:gh_calls) { [] }
  let(:open_trains) { [] }

  STACKED_GIT_IDENTITY = { "GIT_AUTHOR_NAME" => "A", "GIT_AUTHOR_EMAIL" => "a@example.test",
                           "GIT_COMMITTER_NAME" => "A", "GIT_COMMITTER_EMAIL" => "a@example.test" }.freeze

  def git(*args, dir: work)
    out, err, status = Open3.capture3(STACKED_GIT_IDENTITY, "git", *args, chdir: dir)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?

    out.strip
  end

  def commit(name)
    File.write(File.join(work, name), name)
    git("add", name)
    git("commit", "-q", "-m", name)
    git("rev-parse", "HEAD")
  end

  # The stub GitHub: lists the open trains as REST does, opens a PR and turns on auto-merge.
  def github(argv, **)
    gh_calls << argv
    return [true, JSON.generate(open_trains)] if argv[1] == "api"
    return [true, "https://github.test/heckslabs/hecks/pull/9\n"] if argv[1..2] == %w[pr create]

    [true, ""]
  end

  def open_train(number, head)
    open_trains << { "number" => number, "created_at" => "2026-11-18T12:0#{number}:00Z",
                     "head" => { "ref" => branch_for(head), "sha" => head } }
  end

  def still_mint = instance_double(Hecks::Adapters::GitTrain::MintStep, run: "the Hecks shape did not move")

  def carry = Hecks::Adapters::GitTrain.new(mint: still_mint, runner: method(:github)).carry(checkout: { value: work })

  def refusal
    carry
  rescue Hecks::Adapters::ConsoleCapture::Failure => e
    e.message
  end

  def remote(ref) = git("ls-remote", "origin", ref).split.first

  def branch_for(commit) = Hecks::Adapters::GitTrain::PullRequestBoarding.branch_for(commit)

  def created = gh_calls.find { |argv| argv[1..2] == %w[pr create] }

  before do
    git("init", "-q", "--bare", "-b", "main", "origin.git", dir: scratch)
    git("clone", "-q", "origin.git", work, dir: scratch)
    git("checkout", "-q", "-b", "main")
    commit("first")
    git("push", "-q", "origin", "main")
  end

  after { FileUtils.remove_entry(scratch) }

  it "stacks a boarding on the open train's head and names it in the report", :aggregate_failures do
    open_train(1, commit("second"))
    boarded = commit("third")

    expect(carry[:report][:value]).to include("stacked on #1 (#{branch_for(git("rev-parse", "HEAD~1"))}")
    expect(remote("refs/heads/#{branch_for(boarded)}")).to eq(boarded)
  end

  it "opens the stacked pull request into main, its body naming the train beneath it", :aggregate_failures do
    open_train(1, commit("second"))
    commit("third")
    carry

    expect(created.each_cons(2).to_a).to include(%w[--base main])
    expect(created.last).to include("Stacked on #1")
  end

  it "refuses a third train by name and pushes nothing", :aggregate_failures do
    open_train(1, commit("second"))
    open_train(2, commit("third"))
    boarded = commit("fourth")

    expect(refusal).to include("2 trains in flight (#1, #2): board again when one merges")
    expect(remote("refs/heads/#{branch_for(boarded)}")).to be_nil
  end

  it "refuses a boarding the open train's head is not beneath" do
    git("checkout", "-q", "-b", "side")
    open_train(1, commit("aside"))
    git("checkout", "-q", "main")
    commit("second")

    expect(refusal).to match(/the open train #1 at \h{9} is not beneath \h{9}: board again/)
  end

  it "does not count a train whose head main already holds" do
    open_train(1, git("rev-parse", "HEAD"))
    commit("second")

    expect(carry[:report][:value]).not_to include("stacked on")
  end

  it "does not count the boarding's own branch, as when a boarding is retried" do
    boarded = commit("second")
    open_train(1, boarded)

    expect(carry).to include(outcome: { value: "queued" })
  end
end
