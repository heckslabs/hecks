require "spec_helper"

# Adapters answer "did X land, when, in which batch" from the ledger and the event journal;
# a raw read of git history is allowed only where the answer is a git fact (remote carriage, commit
# ancestry, ordering, counts), and each such file is listed here with the reason. The scan covers
# `lib/hecks/hecks/adapters`; the vendored delivery adapters under `embryonaut_bluebooks` are outside
# it on purpose.
module GitHistoryReads
  ROOT = File.expand_path("..", __dir__)
  ROOTS = %w[lib/hecks/hecks/adapters].freeze
  SUBCOMMANDS = %w[log rev-list show merge-base name-rev describe cat-file].freeze
  QUOTED = /"(?:#{SUBCOMMANDS.join("|")})"/
  SHELLED = /\bgit (?:-C \S+ )?(?:#{SUBCOMMANDS.join("|")})\b/
  GIT_WORD = /\bgit\b/i
  ALLOWED = {
    "codebase/bluebook_extraction.rb" => "merge-base picks the diff base of the bluebooks a branch changed: ancestry",
    "codebase/impacted_specs.rb"      => "merge-base picks the diff base of a branch: ancestry is git",
    "codebase/release_facts.rb"       => "trailer of the commit that set the version: message text is git",
    "doctor_reading.rb"               => "commits main is ahead of origin/main: the remote's state is git",
    "git_refs.rb"                     => "ancestry, first-parent order and commit times: the ledger has no parentage",
    "work_landings.rb"                => "the commit on main whose branch or message names a work item: ancestry"
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
