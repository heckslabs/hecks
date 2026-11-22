# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/github_pull_requests/train_sweep"
require_relative "support/train_branch_github"

# A train branch is never reused, so once its pull request is merged or closed the sweep deletes
# it from origin, and keeps the branch of an open pull request or of one not yet settled.
RSpec.describe Hecks::Adapters::GithubPullRequests::TrainSweep do
  let(:github) { TrainBranchGithub.new }

  before do
    pull = TrainBranchGithub.method(:pull)
    github.refs = %w[train/main-aaa train/main-bbb train/main-ccc train/main-ddd train/main-eee train/main-fff]
    github.closed = [pull.call(1, "train/main-aaa", merged: TrainBranchGithub::OLD),
                     pull.call(2, "train/main-bbb", closed: TrainBranchGithub::OLD),
                     pull.call(4, "train/main-ddd", closed: TrainBranchGithub::FRESH)]
    github.open = [pull.call(3, "train/main-ccc", state: "open")]
  end

  def sweep = described_class.new(github, ->(_args) { [false, ""] }, now: TrainBranchGithub::NOW).run

  it "deletes the branch of a merged pull request and of one closed past the grace period" do
    sweep
    expect(github.deleted).to contain_exactly("train/main-aaa", "train/main-bbb")
  end

  it "keeps the branch of an open pull request, of a recent closure, and of one with none" do
    sweep
    expect(github.deleted).not_to include("train/main-ccc", "train/main-ddd", "train/main-fff", "train/main-eee")
  end

  it "names each deletion in its report" do
    expect(sweep).to include("deleted train/main-aaa: #1 merged", "deleted train/main-bbb: #2 closed")
  end

  it "keeps a branch GitHub refuses to delete and still deletes the others" do
    github.refusing = ["train/main-aaa"]
    expect(sweep).to include(a_string_starting_with("kept train/main-aaa"), "deleted train/main-bbb: #2 closed")
  end

  it "reads only branches under the train prefix" do
    sweep
    expect(github.paths.grep(/matching-refs/)).to all(end_with("heads/train/main-"))
  end
end
