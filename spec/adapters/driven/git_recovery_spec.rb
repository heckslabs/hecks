require "spec_helper"
require "hecks/hecks/adapters/git_checkout"

# The stash entries and the unreachable commits of a checkout, read from canned git output, with no
# repository touched. Every git call the reads make is recorded: each is a read, and none applies,
# pops, drops, branches, prunes, collects or repairs anything.
module RecoveryReads
  Answer = Struct.new(:out, :err, :status) do
    def ok? = status.zero?
  end

  # Answers each git call from a table keyed by its subcommand; `show` is keyed by its commit.
  class Runner
    attr_reader :calls

    def initialize(answers)
      @answers = answers
      @calls = []
    end

    def capture(*args, chdir: nil)
      @calls << args
      Answer.new(answer_for(args), "", 0)
    end

    private

    def answer_for(args)
      answer = @answers.fetch(args.first) { raise "unexpected git #{args.join(" ")}" }
      answer.is_a?(Hash) ? answer.fetch(args.last) : answer
    end
  end
end

RSpec.describe "the stashes and dangling commits of a checkout" do
  def sha_old = "a" * 40

  def sha_new = "b" * 40

  def stash_lines
    "stash@{0}\t2026-11-03T10:00:00+00:00\tWIP on feat/a: 1a2b3c4 Add thing\n" \
      "stash@{1}\t2026-10-20T09:00:00+00:00\tOn main: scratch before rebase\n" \
      "stash@{2}\t2026-10-01T08:00:00+00:00\tsomething with no branch recorded\n"
  end

  def stash_report
    [
      "stash@{0}\t2026-11-03T10:00:00+00:00\tfeat/a\tWIP on feat/a: 1a2b3c4 Add thing",
      "stash@{1}\t2026-10-20T09:00:00+00:00\tmain\tOn main: scratch before rebase",
      "stash@{2}\t2026-10-01T08:00:00+00:00\tno branch recorded\tsomething with no branch recorded"
    ].join("\n")
  end

  def fsck
    "unreachable blob #{"c" * 40}\nunreachable commit #{sha_old}\n" \
      "unreachable tree #{"d" * 40}\nunreachable commit #{sha_new}\n"
  end

  def shows
    {
      sha_old => "#{sha_old}\t2026-09-01T10:00:00+00:00\tOld experiment",
      sha_new => "#{sha_new}\t2026-10-05T12:00:00+00:00\tWIP: retry the gate"
    }
  end

  def runner
    RecoveryReads::Runner.new("rev-parse" => Dir.pwd, "stash" => stash_lines, "fsck" => fsck, "show" => shows)
  end

  def reads_with(answers) = Hecks::Adapters::GitRecovery.new(RecoveryReads::Runner.new(answers), "/repo")

  def reads_over(runner) = Hecks::Adapters::GitRecovery.new(runner, "/repo")

  def read_calls_only(runner)
    reads = reads_over(runner)
    reads.stashes
    reads.dangling_commits
    runner.calls
  end

  it "names each stash entry's ref, time, recorded branch and message" do
    expect(reads_over(runner).stashes).to eq(stash_report)
  end

  it "says there are no stashes when the list is empty" do
    expect(reads_with("stash" => "").stashes).to eq("no stashes")
  end

  it "lists each unreachable commit's short sha, author date and subject, newest first" do
    expected = "bbbbbbbbb\t2026-10-05T12:00:00+00:00\tWIP: retry the gate\n" \
               "aaaaaaaaa\t2026-09-01T10:00:00+00:00\tOld experiment"
    expect(reads_over(runner).dangling_commits).to eq(expected)
  end

  it "says there are no dangling commits when fsck names none" do
    expect(reads_with("fsck" => "Checking object directory\n").dangling_commits).to eq("no dangling commits")
  end

  it "runs fsck without repair or pruning, and stash only to list", :aggregate_failures do
    calls = read_calls_only(runner)
    expect(calls.find { |args| args.first == "fsck" }).to eq(%w[fsck --unreachable --no-reflogs])
    expect(calls.select { |args| args.first == "stash" }.map { |args| args[1] }).to all(eq("list"))
    expect(calls.flatten & %w[apply pop drop branch clear gc prune repair --lost-found]).to be_empty
  end

  it "answers the Stashes query through the Reading port's adapter" do
    allow(Hecks::Adapters::Git).to receive(:new).and_return(runner)
    expect(Hecks::Adapters::GitCheckout.new.stashes[:text]).to eq("#{stash_report}\n")
  end
end
