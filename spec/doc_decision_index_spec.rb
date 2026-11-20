require "spec_helper"
require "tmpdir"
require "fileutils"
require "stringio"
require "hecks/doc/regions"

# The decision index is `Tickets::Adr` as the DecisionFiles adapter reads a decision directory:
# each held record linked to its file, with the records that supersede it, and no record whose
# number two files share. Every example reads a temporary checkout, never this one's decisions.
module DecisionIndexFixture
  # Writes one file under the temporary checkout.
  def write(path, text)
    file = File.join(@dir, path)
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, text)
  end

  # Renders the index over the temporary checkout, its Tickets bluebook copied in, with the
  # adapter's left-out lines held back from standard error.
  def rendered
    tickets = Hecks::Doc::Regions::DecisionIndex::TICKETS
    write(tickets, File.read(File.join(InMemoryDomain::ROOT, tickets)))
    held = $stderr
    $stderr = StringIO.new
    Hecks::Doc::Regions::DecisionIndex.render(@dir)
  ensure
    $stderr = held
  end
end

RSpec.describe Hecks::Doc::Regions::DecisionIndex do
  include DecisionIndexFixture

  around do |example|
    Dir.mktmpdir("hecks-decision-index") do |dir|
      @dir = dir
      example.run
    end
  end

  it "lists a held record linked to its file, with what supersedes it" do
    write("docs/decisions/0001-first.md", "# The first\n\n**Status:** Accepted. Date: 2026-11-01.\n")
    write("docs/decisions/0002-second.md", "# The second\n\n**Status:** Accepted. Supersedes [0001](0001-first.md).\n")
    expect(rendered).to include("| [0001](0001-first.md) | The first | accepted | 0002 |  |")
  end

  it "never reads the index page beside the records as a record" do
    write("docs/decisions/0001-first.md", "# The first\n\n**Status:** Accepted.\n")
    write("docs/decisions/README.md", "# Decisions\n\n**Status:** Accepted.\n")
    expect(rendered.lines.grep(/^\| \[/).size).to eq(1)
  end

  it "leaves out a number two files share" do
    write("docs/decisions/0003-a.md", "# Twin a\n\n**Status:** Accepted.\n")
    write("docs/decisions/0003-b.md", "# Twin b\n\n**Status:** Accepted.\n")
    expect(rendered).not_to include("0003")
  end
end
