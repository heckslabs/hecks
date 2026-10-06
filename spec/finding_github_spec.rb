require "spec_helper"
require "hecks/hecks/adapters/finding_github"

# The GitHubIssues port's adapter drives one issue from a finding with `gh`. These examples stub
# `gh`, recording each call, so nothing here reaches GitHub.
RSpec.describe Hecks::Adapters::FindingGithub do
  let(:adapter) { described_class.new(settings: { repository: "acme/widgets" }) }
  let(:ok)      { instance_double(Process::Status, success?: true) }
  let(:red)     { instance_double(Process::Status, success?: false) }
  let(:calls)   { [] }

  def stub_gh(out: "", err: "", status: ok)
    allow(Open3).to receive(:capture3) do |*arguments|
      calls << arguments
      [out, err, status]
    end
  end

  def gh_call(*arguments) = ["gh", *arguments, "--repo", "acme/widgets"]

  it "opens an issue and answers its number", :aggregate_failures do
    stub_gh(out: "https://github.com/acme/widgets/issues/42\n")

    answer = adapter.open_issue(title: { value: "A gap" }, body: { value: "details" })

    expect(answer).to eq(issue_number: { value: 42 })
    expect(calls).to eq([gh_call("issue", "create", "--title", "A gap", "--body", "details")])
  end

  it "labels the issue with the finding's kind and severity" do
    stub_gh

    adapter.label_issue(issue_number: { value: 7 }, kind: { value: "gap" }, severity: { value: "high" })

    expect(calls).to eq([gh_call("issue", "edit", "7", "--add-label", "kind:gap,severity:high")])
  end

  it "closes a resolved finding as completed" do
    stub_gh

    adapter.close_issue(issue_number: { value: 7 }, status: { value: "resolved" })

    expect(calls).to eq([gh_call("issue", "close", "7", "--reason", "completed")])
  end

  it "closes a dismissed finding as not planned" do
    stub_gh

    adapter.close_issue(issue_number: { value: 7 }, status: { value: "dismissed" })

    expect(calls).to eq([gh_call("issue", "close", "7", "--reason", "not planned")])
  end

  it "refuses every ask when no repository is named, and calls nothing", :aggregate_failures do
    stub_gh
    stub_const("ENV", ENV.to_h.except(described_class::REPOSITORY_VARIABLE))

    expect { described_class.new.open_issue(title: "t", body: "b") }.to raise_error(/no repository named/)
    expect(calls).to be_empty
  end

  it "refuses an ask that needs an issue the finding never got", :aggregate_failures do
    stub_gh

    expect { adapter.reopen_issue(title: "t") }.to raise_error(/no GitHub issue yet/)
    expect(calls).to be_empty
  end

  it "raises with what gh printed when it exits non-zero" do
    stub_gh(err: "HTTP 404", status: red)

    expect { adapter.close_issue(issue_number: 7) }.to raise_error(/gh issue close failed — HTTP 404/)
  end
end
