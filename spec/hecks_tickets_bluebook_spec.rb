require "spec_helper"

# The Tickets bluebook is attached to the Hecks domain: Finding, Adr, Work, Lesson and Sighting are
# declared in it, the finding's lifecycle drives GitHub through the GitHubIssues port, a refused ask
# never blocks the finding, and a Work step stays inside Hecks.
RSpec.describe "the Tickets bluebook" do
  def declared = %w[Finding Adr Work Lesson Sighting]

  before(:all) do
    @hecks = InMemoryDomain.boot_hecks_in_memory
    @bluebook = @hecks.registry.bluebook("Tickets")
  end

  it "declares its aggregates, and leaves Release to the Hecks domain and Ticket to QualityControl" do
    expect(@bluebook.aggregates.map(&:hecks_name)).to contain_exactly(*declared)
  end

  it "boots standing alone, as a fuzz or model_check boot of its directory does" do
    standalone = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/tickets/bluebook"), install_driving: false)

    expect(standalone.registry.bluebook("Tickets").aggregates.map(&:hecks_name)).to contain_exactly(*declared)
  end

  it "gives a Finding the commands of its lifecycle" do
    commands = @bluebook.aggregate("Finding").commands.map(&:hecks_name)

    expect(commands).to include("Report", "Triage", "LinkFix", "Resolve", "Dismiss", "Reopen")
  end

  it "lets the Hecks domain's Release record the findings a version settled" do
    release = @hecks.registry.bluebook("Hecks").aggregate("Release")

    expect(release.commands.map(&:hecks_name)).to include("CloseFindings")
  end

  it "records the issue number only from the answer that carries it" do
    policies = @bluebook.policies.to_h { |policy| [policy.hecks_name, policy.event_name] }

    expect(policies["RecordTheIssue"]).to eq("IssueOpened")
  end

  # Reports a finding with no findings repository set, so GitHub cannot be driven; answers what the
  # launcher printed and the policies that reacted.
  def report_without_a_repository(key = "f-1")
    allow(Open3).to receive(:capture3)
    stub_const("ENV", ENV.to_h.except("HECKS_FINDINGS_REPO"))
    before = @hecks.registry.reaction_log.size
    argv = ["tickets", "finding.report!", "finding.value=#{key}", "title.value=A gap", "source.value=maintainer"]

    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, program: "hecks", argv: argv)
    [out, @hecks.registry.reaction_log.drop(before).map { |reaction| reaction[:policy] }]
  end

  it "keeps a reported finding when GitHub cannot be driven, and records why", :aggregate_failures do
    out, reacted = report_without_a_repository

    expect(JSON.parse(out).dig("state", "status")).to eq("reported")
    expect(reacted).to include("OpenIssueWhenReported", "RecordTheSyncFailure")
    expect(Open3).not_to have_received(:capture3)
  end

  def draft_adr(adr, settles)
    @hecks.dispatch_flat("Tickets::Adr.Draft", adr: adr, title: "Settle it", settles: settles)
  end

  it "accepts an Adr that settles a finding which exists" do
    report_without_a_repository("f-settled")
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

  it "files a finding when a conformance or gate run faults", :aggregate_failures do
    policies = @bluebook.policies.map(&:hecks_name)

    expect(policies).to include("ReportWhenConformanceFaulted", "ReportWhenGateFaulted", "OpenIssueWhenRunReported")
    expect(@bluebook.aggregate("Finding").commands.map(&:hecks_name)).to include("ReportFailedRun")
  end

  it "drives GitHub from each lifecycle event, and records the answer or the refusal" do
    policies = @bluebook.policies.map(&:hecks_name)

    expect(policies).to include("OpenIssueWhenReported", "LabelIssueWhenTriaged", "CloseIssueWhenResolved",
                                "ReopenIssueWhenReopened", "RecordTheIssue", "RecordTheSyncFailure")
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
