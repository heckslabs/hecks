require "hecks"
require_relative "../../lib/hecks/quality_control/adapters/github_issues"

# Transport only: `Open3.capture3` is stubbed so the suite never shells out to a real `gh`.
RSpec.describe Hecks::Adapters::GithubIssues do
  subject(:adapter) { described_class.new }

  let(:ticket) do
    { reference: { value: "BUG#9" }, repository: { value: "heckslabs/other" },
      title: { value: "a thing we could not fix" }, body: { value: "it breaks" }, pull_request: { value: "" } }
  end

  def gh_result(stdout, success: true, stderr: "")
    [stdout, stderr, instance_double(Process::Status, success?: success)]
  end

  def gh_answers(stdout, **)
    allow(Open3).to receive(:capture3).and_return(gh_result(stdout, **))
  end

  def gh_creates(body, stdout)
    allow(Open3).to receive(:capture3)
      .with("gh", "issue", "create", "--repo", "heckslabs/other", "--title", "a thing we could not fix", "--body", body)
      .and_return(gh_result(stdout))
  end

  it "files the ticket as an issue and answers with its number and URL" do
    gh_creates("it breaks", "https://github.com/heckslabs/other/issues/43\n")

    expect(adapter.file(**ticket))
      .to eq(number: { value: 43 }, url: { value: "https://github.com/heckslabs/other/issues/43" })
  end

  it "points at a proposed fix in the body when the ticket carries one" do
    gh_creates("it breaks\n\nA fix is proposed in https://github.com/heckslabs/hecks/pull/9",
               "https://github.com/heckslabs/other/issues/44")

    filed = adapter.file(**ticket, pull_request: { value: "https://github.com/heckslabs/hecks/pull/9" })

    expect(filed[:number]).to eq(value: 44)
  end

  it "reads bare strings as well as materialized value objects" do
    gh_answers("https://github.com/heckslabs/other/issues/45")

    expect(adapter.file(repository: "heckslabs/other", title: "t", body: "b")[:number]).to eq(value: 45)
  end

  it "raises what gh said when it refuses, for the runtime to record as the ticket's refusal" do
    gh_answers("", success: false, stderr: "HTTP 401: the token expired")

    expect { adapter.file(**ticket) }
      .to raise_error(RuntimeError, /gh issue create failed — HTTP 401: the token expired/)
  end

  it "raises when gh prints no issue URL" do
    gh_answers("created something\n")

    expect { adapter.file(**ticket) }.to raise_error(RuntimeError, /printed no issue URL/)
  end
end
