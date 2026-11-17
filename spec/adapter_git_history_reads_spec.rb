require "spec_helper"

# Pipeline adapters answer "did X land, when, in which batch" from the ledger and the event journal;
# a raw read of git history is allowed only where the answer is a git fact (remote carriage, commit
# ancestry, ordering, counts), and each such file is listed here with the reason. The scan covers
# `lib/hecks/hecks/adapters` and `lib/hecks/pipeline_board`; the vendored delivery adapters under
# `embryonaut_bluebooks` are outside it on purpose.
module GitHistoryReads
  ROOT = File.expand_path("..", __dir__)
  ROOTS = %w[lib/hecks/hecks/adapters lib/hecks/pipeline_board].freeze
  SUBCOMMANDS = %w[log rev-list show merge-base name-rev describe cat-file].freeze
  QUOTED = /"(?:#{SUBCOMMANDS.join("|")})"/
  SHELLED = /\bgit (?:-C \S+ )?(?:#{SUBCOMMANDS.join("|")})\b/
  GIT_WORD = /\bgit\b/i
  ALLOWED = {
    "claude_cleaning/worktree_check.rb"       => "unpushed commits of a worktree before removal: a checkout fact",
    "codebase/impacted_specs.rb"              => "merge-base picks the diff base of a branch: ancestry is git",
    "codebase/release_facts.rb"               => "trailer of the commit that set the version: message text is git",
    "desktop_alert.rb"                        => "subjects of the commits a push carried, shown in a notification",
    "dispatching/landed_since.rb"             => "commit time of a given sha; no event yet carries the landed time",
    "doctor_reading.rb"                       => "commits main is ahead of origin/main: the remote's state is git",
    "git_main_pull/boarding.rb"               => "subjects in the range of main being pulled: ancestry and order",
    "git_refs.rb"                             => "ancestry, first-parent order and commit times: the ledger has no parentage",
    "git_rehearsal/due.rb"                    => "how far main is ahead of its tracking branch and since when",
    "git_rehearsal/record.rb"                 => "orders rehearsal records by ancestry, else commit time",
    "git_train.rb"                            => "commits a boarding carries beyond the remote: the push has not happened",
    "git_train/carriage.rb"                   => "what the remote carries after a push and what waits behind it",
    "git_train/landings.rb"                   => "merges a boarding carries beyond the remote main, read before BranchPushed",
    "git_train/pull_request_boarding.rb"      => "commits waiting behind a boarded commit on main: ancestry",
    "git_train/reverting.rb"                  => "parent count of a merge decides how it is reverted: commit shape",
    "git_train/survey.rb"                     => "newest commit and ahead counts of each branch: ancestry",
    "git_worktrees.rb"                        => "commit counts between refs of a worktree: ancestry",
    "github_pull_requests/train_sweep.rb"     => "whether a commit is in main: the squash lands after the push",
    "main_integration/boarded_check.rb"       => "whether a train commit is in the remote main: remote carriage",
    "main_integration/carried_check.rb"       => "whether origin/main carries a landed commit, squash too: remote",
    "main_integration/newest_first.rb"        => "unpushed commits of main in topological order: ancestry",
    "main_integration/repository.rb"          => "merges and messages between two commits: no parentage in the ledger",
    "main_integration/standing.rb"            => "commits since a landed one, direct and adopted included: a count",
    "run_activity.rb"                         => "time of the newest commit not on origin: unpushed work of a checkout",
    "pipeline_board/adapters/pipeline_git.rb" => "board facts about main, origin, stable: ahead counts, times"
  }.freeze

  module_function

  # @param source [String] Ruby source
  # @return [Array<Integer>] the line numbers of code lines that read git history
  def hits(source)
    lines = source.lines
    return [] unless lines.any? { |line| code?(line) && line.match?(GIT_WORD) }

    lines.each_with_index.filter_map { |line, index| index + 1 if code?(line) && history?(line) }
  end

  def history?(line) = line.match?(QUOTED) || line.match?(SHELLED)

  def code?(line) = !line.strip.start_with?("#")

  # @return [String] the path under `lib/hecks/hecks/adapters`, or under `lib/hecks` for the board
  def label(path, root)
    path.delete_prefix("#{root}/").delete_prefix("lib/hecks/hecks/adapters/").delete_prefix("lib/hecks/")
  end

  # @return [Hash{String => Array<Integer>}] labelled file to the lines that read history
  def scan(root = ROOT)
    files = ROOTS.flat_map { |dir| Dir.glob(File.join(root, dir, "**/*.rb")) }.sort
    found = files.to_h { |path| [label(path, root), hits(File.read(path))] }
    found.reject { |_file, lines| lines.empty? }
  end
end

RSpec.describe "adapter reads of git history" do
  it "finds a quoted history subcommand in a git call", :aggregate_failures do
    expect(GitHistoryReads.hits("git(dir, \"rev-list\", \"--count\")\n")).to eq([1])
    expect(GitHistoryReads.hits("`git log -1`\n")).to eq([1])
  end

  it "ignores a comment and a non-git file" do
    expect(GitHistoryReads.hits("# git rev-list\nui.run(\"show\")\n")).to be_empty
  end

  it "names no adapter file outside the allowlist" do
    found = GitHistoryReads.scan
    extra = (found.keys - GitHistoryReads::ALLOWED.keys).map { |file| "#{file}:#{found[file].first}" }
    expect(extra).to be_empty, "git history read outside the allowlist: #{extra}. " \
                               "Ask the ledger or journal, or list the file with a reason."
  end

  it "lists no file that no longer reads git history" do
    expect(GitHistoryReads::ALLOWED.keys - GitHistoryReads.scan.keys).to be_empty
  end

  it "gives every allowed file a reason" do
    expect(GitHistoryReads::ALLOWED.values.map(&:strip)).to all(satisfy { |reason| reason.length > 10 })
  end
end
