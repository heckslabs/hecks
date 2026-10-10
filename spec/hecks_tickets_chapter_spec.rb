require "spec_helper"

# The Tickets chapter is attached to the Hecks domain: Finding and Adr are declared in it,
# the finding's lifecycle drives GitHub through the GitHubIssues port, and a refused ask never blocks
# the finding.
RSpec.describe "the Tickets chapter" do
  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false)
    @bluebook = @hecks.registry.bluebook("Tickets")
  end

  it "declares Finding and Adr, and leaves Release to the Hecks domain and Ticket to QualityControl" do
    expect(@bluebook.aggregates.map(&:hecks_name)).to contain_exactly("Finding", "Adr")
  end

  it "boots standing alone, as a fuzz or model_check boot of its directory does" do
    standalone = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/tickets/bluebook"), install_driving: false)

    expect(standalone.registry.bluebook("Tickets").aggregates.map(&:hecks_name)).to contain_exactly("Finding", "Adr")
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
  def report_without_a_repository
    allow(Open3).to receive(:capture3)
    stub_const("ENV", ENV.to_h.except("HECKS_FINDINGS_REPO"))
    before = @hecks.registry.reaction_log.size
    argv = ["tickets", "finding.report", "finding.value=f-1", "title.value=A gap", "source.value=maintainer"]

    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, program: "hecks", argv: argv)
    [out, @hecks.registry.reaction_log.drop(before).map { |reaction| reaction[:policy] }]
  end

  it "keeps a reported finding when GitHub cannot be driven, and records why", :aggregate_failures do
    out, reacted = report_without_a_repository

    expect(JSON.parse(out).dig("state", "status")).to eq("reported")
    expect(reacted).to include("OpenIssueWhenReported", "RecordTheSyncFailure")
    expect(Open3).not_to have_received(:capture3)
  end

  it "lists a reported finding among the open ones" do
    argv = ["tickets", "finding.report", "finding.value=f-open", "title.value=Still open", "source.value=maintainer"]
    Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, program: "hecks", argv: argv)

    out, = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, program: "hecks", argv: ["tickets", "finding.open"])

    expect(JSON.parse(out).map { |row| row.dig("finding", "value") }).to include("f-open")
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
end
