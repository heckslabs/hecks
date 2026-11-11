require "spec_helper"
require "json"
require_relative "support/fake_train_github"

# Open train pull requests that do not need to be open are closed with a comment naming why: one
# whose tip main already holds, and a red one a newer train pull request carries the tip of.
RSpec.describe Hecks::Adapters::GithubPullRequests do
  let(:github) { FakeTrainGithub.new }

  def checks(conclusion) = [{ name: "rspec", status: "COMPLETED", conclusion: conclusion }]

  def pull(number, oid, day, conclusion)
    { number: number, headRefName: "train/main-#{oid[0, 12]}", headRefOid: oid, createdAt: "2026-11-#{day}T00:00:00Z",
      statusCheckRollup: checks(conclusion) }
  end

  def sweep(held: {})
    adapter = described_class.new(runner: github.method(:gh), git_runner: github.git(held: held))
    adapter.tidy[:report][:value]
  end

  it "closes a red pull request whose tip a newer one carries, naming its successor" do
    github.pulls = [pull(1332, "a" * 40, "10", "FAILURE"), pull(1335, "c" * 40, "11", "SUCCESS")]
    expect(sweep(held: { "a" * 40 => ["c" * 40] })).to include("closed #1332: superseded by #1335")
  end

  it "closes a pull request whose tip main already holds" do
    github.pulls = [pull(1286, "d" * 40, "01", "SUCCESS")]
    expect(sweep(held: { "d" * 40 => ["origin/main"] })).to include("closed #1286", "is on main already")
  end

  it "leaves a pull request alone that nothing supersedes" do
    github.pulls = [pull(1340, "e" * 40, "11", "FAILURE")]
    expect(sweep).to eq("no train pull request to close")
  end
end
