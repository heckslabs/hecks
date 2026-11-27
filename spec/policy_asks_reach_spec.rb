require "spec_helper"
require "securerandom"

# An event reaches its policy's port and is not refused on the way: a run's reported finding
# must reach GitHubIssues.OpenIssue. The `gh` call is stubbed, so nothing reaches GitHub or a
# live database.
RSpec.describe "a policy's ask reaches its port" do
  before(:all) { @hecks = InMemoryDomain.boot_hecks_in_memory }

  let(:ok) { instance_double(Process::Status, success?: true) }

  def key(prefix) = "#{prefix}-#{SecureRandom.hex(4)}"

  # Dispatches `verb` with `args`; answers the policies refused and the triggers fired after it.
  def dispatched(verb, args)
    before = @hecks.registry.reaction_log.size
    result = @hecks.dispatch_flat(verb, args)
    fired = @hecks.registry.reaction_log.drop(before).map { |reaction| reaction[:trigger] }
    [result.refused_reactions.map { |refusal| refusal[:policy] }, fired]
  end

  # Names a findings repository and answers every `gh` call with an issue URL, so none is made.
  def stub_findings_repo
    allow(Open3).to receive(:capture3)
      .and_return(["https://github.com/acme/widgets/issues/9\n", "", ok])
    stub_const("ENV", ENV.to_h.merge("HECKS_FINDINGS_REPO" => "acme/widgets"))
  end

  it "reaches GitHubIssues.OpenIssue for a run that reports a finding, and is not refused",
     :aggregate_failures do
    stub_findings_repo
    refused, fired = dispatched("Tickets::Finding.ReportFailedRun",
                                finding: key("run"), title: "a title", body: "body text")

    expect(refused).not_to include("OpenIssueWhenRunReported")
    expect(fired).to include("Tickets::Finding::GitHubIssues.OpenIssue")
  end
end
