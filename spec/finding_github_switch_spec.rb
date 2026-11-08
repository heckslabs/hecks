require "spec_helper"
require "hecks/hecks/adapters/finding_github"

# Builds the adapter over a registry whose Tickets world declares `declared` for `github_issues`,
# with `gh` stubbed so that a call to it is recorded.
module FindingGithubSwitchHelpers
  def adapter(declared)
    world = instance_double(Hecks::Bluebook::World, for_verb: declared)
    registry = instance_double(Hecks::Runtime::Registry, world: world)
    Hecks::Adapters::FindingGithub.new(settings: { repository: "acme/widgets" }, registry: registry)
  end

  def stub_gh
    done = instance_double(Process::Status, success?: true)
    allow(Open3).to receive(:capture3).and_return(["https://github.com/acme/widgets/issues/9\n", "", done])
  end

  def run_finding = { source: { value: "qa_loop" }, title: { value: "A run failed" }, body: { value: "b" } }

  def other_finding = run_finding.merge(source: { value: "maintainer" })

  def committed_world = File.read(File.expand_path("../lib/hecks/hecks/tickets.world", __dir__))
end

# The Tickets world's `github_issues` switch keeps run findings off GitHub.
RSpec.describe Hecks::Adapters::FindingGithub::Switch do
  include FindingGithubSwitchHelpers

  before { stub_gh }

  it "refuses a run finding by name and calls no gh while the world is off", :aggregate_failures do
    expect { adapter(enabled: false).open_issue(**run_finding) }.to raise_error(/switched off.*github_issues/)
    expect(Open3).not_to have_received(:capture3)
  end

  it "is off when the world declares nothing" do
    expect { adapter(nil).open_issue(**run_finding) }.to raise_error(/switched off/)
  end

  it "opens the issue for a run finding once the world turns it on" do
    expect(adapter(enabled: true).open_issue(**run_finding)).to eq(issue_number: { value: 9 })
  end

  it "leaves a finding a person filed alone while the world is off" do
    expect(adapter(enabled: false).open_issue(**other_finding)).to eq(issue_number: { value: 9 })
  end

  it "is declared off in the committed Tickets world" do
    expect(committed_world).to include('github_issues "GitHubIssues", enabled: false')
  end
end
