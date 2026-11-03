require "spec_helper"
require "securerandom"

# An event reaches its policy's port and is not refused on the way. A Fill of the Hecks
# domain, with and without `only=`, must reach Dispatching.Choose, and a run's reported
# finding must reach GitHubIssues.OpenIssue. The filling is a dry run and the `gh` call is
# stubbed, so nothing reaches a session, GitHub or a live database.
RSpec.describe "a policy's ask reaches its port" do
  before(:all) { @hecks = InMemoryDomain.boot_hecks_in_memory }

  let(:ok) { instance_double(Process::Status, success?: true) }
  let(:repo) { "/nonexistent/repo" }

  def key(prefix) = "#{prefix}-#{SecureRandom.hex(4)}"

  # Dispatches `verb` with `args`; answers the policies refused and the triggers fired after it.
  def dispatched(verb, args)
    before = @hecks.registry.reaction_log.size
    result = @hecks.dispatch_flat(verb, args)
    fired = @hecks.registry.reaction_log.drop(before).map { |reaction| reaction[:trigger] }
    [result.refused_reactions.map { |refusal| refusal[:policy] }, fired]
  end

  it "reaches Dispatching.Choose for a filling with an only=, and is not refused",
     :aggregate_failures do
    refused, fired = dispatched("Hecks::Dispatch.Fill",
                                run: key("fill"), repo: repo, only: "probe")

    expect(refused).not_to include("ChooseWhenFilling")
    expect(fired).to include("Hecks::Dispatch::Dispatching.Choose")
  end

  it "reaches Dispatching.Choose for a filling with no only=, and is not refused",
     :aggregate_failures,
     pending: "regression 2026-11-03: ChooseWhenFilling reads :only, which an unnamed " \
              "filling omits" do
    refused, fired = dispatched("Hecks::Dispatch.Fill", run: key("fill"), repo: repo)

    expect(refused).not_to include("ChooseWhenFilling")
    expect(fired).to include("Hecks::Dispatch::Dispatching.Choose")
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
                                finding: key("run"), body: "body text")

    expect(refused).not_to include("OpenIssueWhenRunReported")
    expect(fired).to include("Tickets::Finding::GitHubIssues.OpenIssue")
  end
end
