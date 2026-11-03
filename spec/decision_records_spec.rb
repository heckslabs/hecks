require "spec_helper"
require "tmpdir"
require "hecks/adapters/driven/adr_files"

# ADR 0175: a decision record is its file, and `Tickets::Adr` reads each one's header through the
# AdrFiles adapter. This is the quick gate's `decision_records` check. Every record under
# `docs/decisions` and `docs/implemented/decisions` has a `# Title` first line, a status line
# that leads with a state of the Adr lifecycle, a number no other record holds, and, when it is
# superseded by a named record, a successor that exists.
module DecisionRecords
  ROOT = File.expand_path("..", __dir__)
  GLOB = "docs/{,implemented/}decisions/[0-9][0-9][0-9][0-9]-*.md".freeze
  # Numbers two records shared before the check existed. Renumbering one would rewrite every
  # citation of it, so the list only shrinks.
  KNOWN_DUPLICATES = %w[0018 0029 0030 0036 0054 0055 0058].freeze
  HEADER = Hecks::Adapters::AdrFiles::Header

  module_function

  # @return [Array<Hash>] the header of every record under `root`
  def headers(root = ROOT) = Dir.glob(File.join(root, GLOB)).map { |path| HEADER.read(path) }

  # @return [Array<String>] the Adr lifecycle's states, read from the Tickets bluebook
  def states
    @states ||= Hecks.boot(File.join(ROOT, "lib/hecks/tickets/bluebook"), install_driving: false)
                     .registry.bluebook("Tickets").aggregate("Adr").lifecycle.states
  end

  # @return [Array<String>] one line per problem, empty when every record is sound
  def problems(headers)
    numbers = headers.map { |header| header[:adr] }
    headers.flat_map { |header| [untitled(header), unstated(header), orphaned(header, numbers)].compact } +
      duplicates(headers)
  end

  def untitled(header) = ("#{name(header)} has no `# Title` first line" unless header[:title])

  def unstated(header)
    return if states.include?(header[:status])

    "#{name(header)}'s status line does not lead with one of #{states.map(&:capitalize).join(", ")}"
  end

  def orphaned(header, numbers)
    successor = header[:superseded_by]
    "#{name(header)} is superseded by ADR #{successor}, which no record holds" if successor && !numbers.include?(successor)
  end

  def duplicates(headers)
    (shared(headers) - KNOWN_DUPLICATES).map { |number| "ADR #{number} is held by two records: draft with the next free number" }
  end

  def shared(headers) = headers.group_by { |header| header[:adr] }.select { |_, group| group.size > 1 }.keys

  def name(header) = File.basename(header[:path])
end

RSpec.describe "the decision records" do
  # Writes the files under a new checkout and answers the problems found there.
  def problems_in(files)
    Dir.mktmpdir do |root|
      files.each { |name, text| write_record(root, name, text) }
      DecisionRecords.problems(DecisionRecords.headers(root))
    end
  end

  def write_record(root, name, text)
    FileUtils.mkdir_p(File.join(root, "docs/decisions"))
    File.write(File.join(root, "docs/decisions", name), text)
  end

  it "finds every record in the repository sound" do
    expect(DecisionRecords.problems(DecisionRecords.headers)).to eq([])
  end

  it "drops a number from the known duplicates once it is unique again" do
    expect(DecisionRecords::KNOWN_DUPLICATES - DecisionRecords.shared(DecisionRecords.headers)).to eq([])
  end

  it "refuses a status line that leads with no state of the lifecycle" do
    expect(problems_in("0001-a.md" => "# A\n\n**Status:** Shipped.\n")).to contain_exactly(/0001-a.md's status line/)
  end

  it "refuses two records under one number" do
    files = { "0002-a.md" => "# A\n\n**Status:** Accepted.\n", "0002-b.md" => "# B\n\n**Status:** Proposed.\n" }
    expect(problems_in(files)).to contain_exactly(/ADR 0002 is held by two records/)
  end

  it "refuses a successor no record holds" do
    expect(problems_in("0003-a.md" => "# A\n\n**Status:** Superseded by [ADR 0009](0009-x.md).\n"))
      .to contain_exactly(/superseded by ADR 0009/)
  end
end
