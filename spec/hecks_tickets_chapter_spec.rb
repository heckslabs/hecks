require "spec_helper"

# The Tickets chapter is attached to the Hecks domain: Finding and Adr are declared in it,
# the finding's lifecycle drives GitHub through the GitHubIssues port, and a refused ask never blocks
# the finding.
RSpec.describe "the Tickets chapter" do
  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_doors: false)
    @bluebook = @hecks.registry.bluebook("Tickets")
  end

  it "declares Finding and Adr, and leaves Release to the Hecks domain and Ticket to QualityControl" do
    expect(@bluebook.aggregates.map(&:hecks_name)).to contain_exactly("Finding", "Adr")
  end

  it "gives a Finding the commands of its lifecycle" do
    commands = @bluebook.aggregate("Finding").commands.map(&:hecks_name)

    expect(commands).to include("Report", "Triage", "LinkFix", "Resolve", "Dismiss", "Reopen")
  end

  it "files a finding when a conformance or gate run faults" do
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
