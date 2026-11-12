require "spec_helper"
require "hecks/hecks/adapters/github_pull_requests"
require "json"
require_relative "support/fake_train_github"

# A red train pull request whose tip local main has passed is closed, so the tip that carries the
# fix is not held behind it by the order rule.
RSpec.describe Hecks::Adapters::GithubPullRequests do
  let(:github) { FakeTrainGithub.new }

  def pull(number, oid, conclusion)
    { number: number, headRefName: "train/main-#{oid[0, 12]}", headRefOid: oid, createdAt: "2026-11-12T00:00:00Z",
      statusCheckRollup: [{ name: "rspec", status: "COMPLETED", conclusion: conclusion }] }
  end

  def sweep(oid, conclusion, held)
    github.pulls = [pull(1361, oid, conclusion)]
    described_class.new(runner: github.method(:gh), git_runner: github.git(held: held)).tidy[:report][:value]
  end

  it "closes a red pull request that local main has moved past" do
    expect(sweep("f" * 40, "FAILURE", { "f" * 40 => ["main"] })).to include("closed #1361: local main carries its tip")
  end

  it "keeps a red pull request whose tip is local main itself" do
    expect(sweep("9" * 40, "FAILURE", { "9" * 40 => ["main"], "main" => ["9" * 40] })).to eq("no train pull request to close")
  end

  it "keeps a green pull request that local main has moved past" do
    expect(sweep("8" * 40, "SUCCESS", { "8" * 40 => ["main"] })).to eq("no train pull request to close")
  end
end
