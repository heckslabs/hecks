require "spec_helper"

# The Tickets chapter is attached to the Hecks domain: Ticket, Adr and Release are declared in it,
# the ticket's lifecycle drives GitHub through the GitHubIssues port, and a refused ask never blocks
# the ticket.
RSpec.describe "the Tickets chapter" do
  before(:all) do
    @hecks = Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_doors: false)
    @bluebook = @hecks.registry.bluebook("Tickets")
  end

  it "declares Ticket, Adr and Release" do
    expect(@bluebook.aggregates.map(&:hecks_name)).to contain_exactly("Ticket", "Adr", "Release")
  end

  it "gives a Ticket the commands of its lifecycle" do
    commands = @bluebook.aggregate("Ticket").commands.map(&:hecks_name)

    expect(commands).to include("Report", "Triage", "LinkFix", "Resolve", "Dismiss", "Reopen")
  end

  it "files a ticket when a conformance or gate run faults" do
    policies = @bluebook.policies.map(&:hecks_name)

    expect(policies).to include("ReportWhenConformanceFaulted", "ReportWhenGateFaulted", "OpenIssueWhenRunReported")
    expect(@bluebook.aggregate("Ticket").commands.map(&:hecks_name)).to include("ReportFailedRun")
  end

  it "drives GitHub from each lifecycle event, and records the answer or the refusal" do
    policies = @bluebook.policies.map(&:hecks_name)

    expect(policies).to include("OpenIssueWhenReported", "LabelIssueWhenTriaged", "CloseIssueWhenResolved",
                                "ReopenIssueWhenReopened", "RecordTheIssue", "RecordTheSyncFailure")
  end
end
