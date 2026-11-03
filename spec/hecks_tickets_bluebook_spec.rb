require "spec_helper"

# The Tickets bluebook is attached to the Hecks domain: Finding, Adr, Work, Lesson and Sighting are
# declared in it, a run finding is planned as a work item, and nothing leaves Hecks: no GitHub issue
# is opened for a finding.
RSpec.describe "the Tickets bluebook" do
  def declared = %w[Finding Adr Work Lesson Sighting]

  before(:all) do
    @hecks = InMemoryDomain.boot_hecks_in_memory
    @bluebook = @hecks.registry.bluebook("Tickets")
  end

  it "declares its aggregates, and leaves Release to the Hecks domain and Ticket to QualityControl" do
    expect(@bluebook.aggregates.map(&:hecks_name)).to match_array(declared)
  end

  it "boots standing alone, as a fuzz or model_check boot of its directory does" do
    standalone = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/tickets/bluebook"), install_driving: false)

    expect(standalone.registry.bluebook("Tickets").aggregates.map(&:hecks_name)).to match_array(declared)
  end

  it "gives a Finding the commands of its lifecycle" do
    commands = @bluebook.aggregate("Finding").commands.map(&:hecks_name)

    expect(commands).to include("Report", "Triage", "LinkFix", "Resolve", "Dismiss", "Reopen")
  end

  it "lets the Hecks domain's Release record the findings a version settled" do
    release = @hecks.registry.bluebook("Hecks").aggregate("Release")

    expect(release.commands.map(&:hecks_name)).to include("CloseFindings")
  end

  # Reports a finding through the launcher; answers what it printed and the policies that reacted.
  # A stub that raises on Open3 fails the example if anything calls GitHub.
  def report_finding(key = "f-1")
    allow(Open3).to receive(:capture3) { raise "GitHub must not be called: a finding opens no issue" }
    before = @hecks.registry.reaction_log.size
    argv = ["tickets", "finding.report!", "finding.value=#{key}", "title.value=A gap", "source.value=maintainer"]

    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, program: "hecks", argv: argv)
    [out, @hecks.registry.reaction_log.drop(before).map { |reaction| reaction[:policy] }]
  end

  it "keeps a reported finding with no GitHub call, and no reaction names GitHub", :aggregate_failures do
    out, reacted = report_finding

    expect(JSON.parse(out).dig("state", "status")).to eq("reported")
    expect(reacted).to be_empty
  end

  def draft_adr(adr, settles)
    @hecks.dispatch_flat("Tickets::Adr.Draft", adr: adr, title: "Settle it", settles: settles)
  end

  it "accepts an Adr that settles a finding which exists" do
    report_finding("f-settled")
    expect { draft_adr("0901", "f-settled") }.not_to raise_error
  end

  it "refuses an Adr that settles a finding no one reported" do
    expect { draft_adr("0902", "f-never-reported") }.to raise_error(Hecks::Runtime::NotFound, /f-never-reported/)
  end

  it "lists a reported finding among the open ones" do
    argv = ["tickets", "finding.report!", "finding.value=f-open", "title.value=Still open", "source.value=maintainer"]
    Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, program: "hecks", argv: argv)

    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, program: "hecks", argv: ["tickets", "query", "finding.open"])

    expect(JSON.parse(out).map { |row| row["finding"] }).to include("f-open")
  end

  it "files a finding and plans its work item when a conformance or gate run faults", :aggregate_failures do
    policies = @bluebook.policies.map(&:hecks_name)

    expect(policies).to include("ReportWhenConformanceFaulted", "ReportWhenGateFaulted", "PlanWorkWhenRunFindingReported")
    expect(@bluebook.aggregate("Finding").commands.map(&:hecks_name)).to include("ReportFailedRun")
  end

  # The policy names of every reaction logged after `before`.
  def reactions_since(before)
    @hecks.registry.reaction_log.drop(before).map { |reaction| reaction[:policy] }
  end

  # The keys of the work items `Work.undone` lists, read through the launcher.
  def undone_work_keys
    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, program: "hecks", argv: ["tickets", "query", "work.undone"])
    JSON.parse(out).map { |row| row["work"] }
  end

  it "plans a run finding as a work item, with no GitHub call", :aggregate_failures do
    allow(Open3).to receive(:capture3) { raise "GitHub must not be called: a run finding opens no issue" }
    before = @hecks.registry.reaction_log.size
    @hecks.dispatch_flat("Tickets::Finding.ReportFailedRun", finding: "run-1", body: "gate red")
    expect(reactions_since(before)).to include("PlanWorkWhenRunFindingReported")
    expect(undone_work_keys).to include("run-1")
  end

  it "names no GitHub policy: the bluebook drives nothing outside Hecks", :aggregate_failures do
    policies = @bluebook.policies.map(&:hecks_name)

    expect(policies.grep(/Issue|GitHub/)).to be_empty
    expect(@bluebook.policies.select { |policy| policy.asks? && policy.event_name.start_with?("Finding") }).to be_empty
  end

  it "gives a Work step the commands of its lifecycle" do
    commands = @bluebook.aggregate("Work").commands.map(&:hecks_name)

    expect(commands).to include("Plan", "Start", "Release", "Finish", "Drop", "Lapse", "Yield", "Reopen")
  end

  # The WorkAreas and WorkLimits ports read Hecks's own rows and clock; nothing leaves the process.
  it "asks only Hecks's own ports from a Work step" do
    asks = @bluebook.policies.select { |policy| policy.asks? && policy.event_name.start_with?("Work") }

    expect(asks.map(&:hecks_name)).to contain_exactly("CheckAreaWhenStarted", "CheckCapWhenStarted")
  end

  it "lapses a superseded decision's undone steps" do
    policies = @bluebook.policies.to_h { |policy| [policy.hecks_name, policy.event_name] }

    expect(policies["LapseWorkWhenSuperseded"]).to eq("AdrSuperseded")
  end
end
