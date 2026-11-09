require "spec_helper"
require "tmpdir"
require "fileutils"
require "stringio"

# The decision records are their files under docs/decisions: Tickets::Adr is persisted by the
# DecisionFiles adapter, which fills a Memory store from the files at boot, so Adr.standing and a
# Work item's decision resolve in every process, and which refuses a write while the files back it.
# Every example reads a temporary copy of the Tickets bluebook over a temporary decisions directory,
# never the checkout's own store; the one example over the checkout's docs/decisions only counts.
RSpec.describe "the Adr store read from decision files" do
  def records
    { "0001-first.md"      => "# The first decision\n\n**Status:** Proposed. Date: 2026-11-01.\n\n## Context\n",
      "0002-second.md"     => "# The second decision\n\n**Status:** Accepted. Date: 2026-11-08. Supersedes " \
                              "[0001](0001-first.md)'s plan and\nnarrows nothing.\n\n## Context\n",
      "0003-third.md"      => "# The third decision\n\n**Status:** Shipped, Ruby only (2026-11-09). Narrows " \
                              "[0002](0002-second.md): its\nsecond point.\n\n## Context\n",
      "0004-old.md"        => "# An old decision\n\n**Status:** Superseded by [ADR 0002](0002-second.md) (2026-11-08).\n",
      "0005-odd.md"        => "# An odd one\n\n**Status:** Bridge built and working.\n",
      "0006-a.md"          => "# Twin a\n\n**Status:** Accepted.\n",
      "0006-b.md"          => "# Twin b\n\n**Status:** Accepted.\n",
      "0064-map/02-sub.md" => "# A sub-record\n\n**Status:** Resolved (research, 2026-09-26) · **Type:** research\n" }
  end

  def write(path, text)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end

  def world(directory)
    "Hecks.world \"Tickets\" do\n  persisted_by(\"DecisionFiles\") do\n    directory \"#{directory}\"\n  end\nend\n"
  end

  # Runs the block with standard error held back: the adapter names the files it leaves out there.
  def quietly
    held = $stderr
    $stderr = StringIO.new
    yield
  ensure
    $stderr = held
  end

  def domain = File.join(@root, "tickets", "bluebook")

  before(:all) do
    @root      = Dir.mktmpdir("hecks-decision-files")
    @decisions = File.join(@root, "docs", "decisions")
    records.each { |name, text| write(File.join(@decisions, name), text) }
    FileUtils.mkdir_p(File.dirname(domain))
    FileUtils.cp_r(File.join(InMemoryDomain::ROOT, "lib/hecks/tickets/bluebook"), domain)
    write(File.join(domain, "tickets.world"), world(@decisions))
    @hecks = quietly { Hecks.boot(domain, install_driving: false) }
  end

  after(:all) { FileUtils.remove_entry(@root) }

  # The standalone boot's launcher takes the Tickets commands bare, with no domain word first.
  def cli(*argv, runtime: @hecks)
    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: runtime, program: "hecks", argv: argv)
    JSON.parse(out)
  end

  def numbers(query) = cli(query).map { |row| row["adr"] }

  def row(query, adr) = cli(query).find { |found| found["adr"] == adr }

  def aggregate(name) = @hecks.registry.bluebook("Tickets").aggregate(name)

  def bound_to(name) = Hecks::Ports::Persistence.bind_for(@hecks.registry, "Tickets", aggregate(name)).adapter

  def adapter_over(directory, root)
    quietly { Hecks::Adapters::DecisionFiles.new(aggregate: aggregate("Adr"), settings: { directory: directory }, root: root) }
  end

  it "lists as standing every record whose own status line says it is accepted" do
    expect(numbers("adr.standing")).to eq(%w[0002 0003 0064/02])
  end

  it "reads the first words of the status line and its date as facts", :aggregate_failures do
    second = row("adr.standing", "0002")

    expect(second["wording"]).to eq("Accepted")
    expect(second["date"]).to eq("2026-11-08")
    expect(second["path"]).to end_with("0002-second.md")
  end

  it "derives the superseded side from the superseding record, so a silent status line is not silent" do
    expect(row("adr.superseded", "0001")["superseded_by"]).to eq(%w[0002])
  end

  it "lists among the superseded a record whose own line says so, with the record that did" do
    expect(row("adr.superseded", "0004")["superseded_by"]).to eq(%w[0002])
  end

  it "derives the narrowed side from the narrowing record" do
    expect(row("adr.narrowed", "0002")["narrowed_by"]).to eq(%w[0003])
  end

  it "reads nothing as a decision from a clause that names none" do
    expect(row("adr.narrowed", "0002")["narrows"]).to eq([])
  end

  it "resolves a Work item's decision against the records read from the files" do
    @hecks.dispatch_flat("Tickets::Work.Plan", work: "w-decided", title: "Carry it out", decision: "0002")

    expect(cli("work.undone").find { |found| found["work"] == "w-decided" }["decision"]).to eq("0002")
  end

  it "refuses a Work item's decision no file records" do
    expect { @hecks.dispatch_flat("Tickets::Work.Plan", work: "w-lost", title: "Carry it out", decision: "0099") }
      .to raise_error(Hecks::Runtime::NotFound, /0099/)
  end

  it "refuses a write by name while the files back the store" do
    expect { @hecks.dispatch_flat("Tickets::Adr.Accept", to: "0001") }.to raise_error(Hecks::Refused, /read from/)
  end

  it "refuses a draft by name while the files back the store" do
    expect { @hecks.dispatch_flat("Tickets::Adr.Draft", adr: "0007", title: "New") }.to raise_error(Hecks::Refused, /read from/)
  end

  it "holds the same records in a fresh boot, as a second process does" do
    again = quietly { Hecks.boot(domain, install_driving: false) }

    expect(cli("adr.standing", runtime: again).map { |found| found["adr"] }).to eq(numbers("adr.standing"))
  end

  it "binds only Adr to the files; the other aggregates keep the hecksagon's default", :aggregate_failures do
    expect(bound_to("Adr")).to eq("DecisionFiles")
    expect(bound_to("Finding")).to eq("Memory")
  end

  it "leaves out, and names, a file with a first word no StatusWord row names" do
    adapter = adapter_over(@decisions, @root)

    expect(adapter.left_out).to include(a_string_matching(/0005-odd\.md: status word "Bridge" names no StatusWord row/))
  end

  it "leaves out both files that share a number, and names them on one line", :aggregate_failures do
    adapter = adapter_over(@decisions, @root)

    expect(adapter.left_out).to include(a_string_matching(/number 0006 is .*0006-a\.md and .*0006-b\.md's/))
    expect(adapter.find("0006")).to be_nil
  end

  it "is a plain Memory store, taking writes, where no world names a directory" do
    plain = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/tickets/bluebook"), install_driving: false)

    expect { plain.dispatch_flat("Tickets::Adr.Draft", adr: "0901", title: "Settle it") }.not_to raise_error
  end

  it "refuses by name a directory the world names that does not exist" do
    expect { adapter_over("docs/nowhere", @root) }.to raise_error(Hecks::Runtime::WiringError, %r{docs/nowhere})
  end

  it "accounts for every file under the checkout's docs/decisions, held or named as left out" do
    root    = InMemoryDomain::ROOT
    adapter = adapter_over(File.join(root, "docs/decisions"), root)
    files   = Dir.glob([File.join(root, "docs/decisions/[0-9]*-*.md"), File.join(root, "docs/decisions/[0-9]*-*/[0-9]*-*.md")])

    expect(adapter.count + adapter.left_out.sum { |line| line.scan(/\S+\.md/).size }).to eq(files.size)
  end
end
