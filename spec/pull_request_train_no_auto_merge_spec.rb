require "spec_helper"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/git_train"

# The push train boarding main in a repository that disallows auto-merge: it waits for the PR's
# required checks, then squash-merges it (never with `--admin`), or answers `checks_failed`
# naming the failed checks and leaves the PR open. Against a local bare repository and a clone
# of it; `gh` is a stubbed GitHub that refuses auto-merge and reports the checks it is given,
# one read at a time.
RSpec.describe "the push train boarding main where auto-merge is disallowed", :io do
  let(:scratch) { Dir.mktmpdir("hecks-pr-train-manual") }
  let(:work) { File.join(scratch, "work") }
  let(:gh_calls) { [] }
  let(:reads) { [] }
  let(:pauses) { [] }

  def identity
    { "GIT_AUTHOR_NAME" => "A", "GIT_AUTHOR_EMAIL" => "a@example.test",
      "GIT_COMMITTER_NAME" => "A", "GIT_COMMITTER_EMAIL" => "a@example.test" }
  end

  def merge_commit = "c" * 40

  # What `gh pr view` answers for a PR in each state; `mergedAt` is set only once it has merged.
  def merged_view = JSON.generate(state: "MERGED", mergedAt: "2026-11-08T00:20:00Z", mergeCommit: { oid: merge_commit })

  # The scripted answers of `gh pr view`; each read takes the next, the last repeating.
  def views = (@views ||= [merged_view])

  def merge_reply(argv) = argv.include?("--auto") ? [false, refusal] : [true, ""]

  def next_checks = reads.size > 1 ? reads.shift : reads.first

  def next_view = views.size > 1 ? views.shift : views.first

  def queued_view = JSON.generate(state: "OPEN", mergedAt: nil, mergeCommit: nil)

  def dropped_view = JSON.generate(state: "CLOSED", mergedAt: nil, mergeCommit: nil)

  def refusal = "GraphQL: Auto merge is not allowed for this repository (enablePullRequestAutoMerge)"

  def git(*args, dir: work)
    out, err, status = Open3.capture3(identity, "git", *args, chdir: dir)
    raise "git #{args.join(" ")} failed: #{err}" unless status.success?

    out.strip
  end

  def checks(*buckets) = reads << JSON.generate(buckets.map { |name, bucket| { name: name, bucket: bucket } })

  # The stubbed GitHub. Each read of the checks takes the next scripted answer, the last repeating.
  def github(argv, **)
    gh_calls << argv
    case argv[1..2]
    when %w[pr create] then [true, "https://github.test/o/r/pull/7\n"]
    when %w[pr merge] then merge_reply(argv)
    when %w[pr checks] then [true, next_checks]
    when %w[pr view] then [true, next_view]
    else [false, "unexpected #{argv.join(" ")}"]
    end
  end

  def still_mint = instance_double(Hecks::Adapters::GitTrain::MintStep, run: "the Hecks shape did not move")

  def carry
    train = Hecks::Adapters::GitTrain.new(mint: still_mint, runner: method(:github), pause: ->(seconds) { pauses << seconds })
    train.carry(checkout: { value: work })
  end

  def board(*buckets)
    checks(*buckets)
    File.write(File.join(work, "second"), "second")
    git("add", "second")
    git("commit", "-q", "-m", "second")
    carry
  end

  def merged_by_squash = gh_calls.select { |argv| argv[1..2] == %w[pr merge] && !argv.include?("--auto") }

  before do
    git("init", "-q", "--bare", "-b", "main", "origin.git", dir: scratch)
    git("clone", "-q", "origin.git", work, dir: scratch)
    git("checkout", "-q", "-b", "main")
    File.write(File.join(work, "first"), "first")
    git("add", "first")
    git("commit", "-q", "-m", "first")
    git("push", "-q", "origin", "main")
  end

  after { FileUtils.remove_entry(scratch) }

  context "when the required checks go green" do
    before { checks(["rspec", "pending"]) }

    it "waits, squash-merges the PR by its number and answers pushed with the merge commit", :aggregate_failures do
      answer = board(["rspec", "pass"])

      expect(answer).to include(outcome: { value: "pushed" }, pushed: { value: merge_commit })
      expect(merged_by_squash).to eq([["gh", "pr", "merge", "7", "--squash"]])
      expect(pauses).to eq([Hecks::Adapters::GitTrain::MergeWhenGreen::INTERVAL])
    end
  end

  context "when the merge call only enqueues the PR" do
    before { checks(["rspec", "pass"]) }

    it "answers pushed only once the queue has merged it, pausing meanwhile", :aggregate_failures do
      views.replace([queued_view, queued_view, queued_view, merged_view])

      expect(board(["rspec", "pass"])).to include(outcome: { value: "pushed" }, pushed: { value: merge_commit })
      expect(pauses.size).to eq(2)
    end

    it "faults, naming the queue, when the queue drops the PR unmerged" do
      views.replace([queued_view, dropped_view])

      expect { board(["rspec", "pass"]) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, %r{merge queue dropped train/main-\w+ \(closed\)})
    end
  end

  context "when a required check fails" do
    it "answers checks_failed naming the failed checks, merging nothing", :aggregate_failures do
      answer = board(["rspec", "fail"], ["rubocop", "pass"], ["fuzz", "cancel"])

      expect(answer).to include(outcome: { value: "checks_failed" })
      expect(answer.dig(:report, :value)).to include("rspec, fuzz")
      expect(merged_by_squash).to be_empty
    end
  end

  it "never passes --admin" do
    board(["rspec", "pass"])

    expect(gh_calls.flatten).not_to include("--admin")
  end

  describe Hecks::Adapters::GitTrain::MergeWhenGreen do
    it "refuses, leaving the PR open, when the checks never settle" do
      waiting = described_class.new(->(_argv, **) { [true, "[]"] }, scratch, pause: ->(_seconds) {}, reads: 3)

      expect { waiting.settle("train/main-x", "7", "a" * 40) }
        .to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /did not finish/)
    end
  end
end
