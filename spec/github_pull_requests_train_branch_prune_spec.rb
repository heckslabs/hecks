# frozen_string_literal: true

require "spec_helper"
require "json"
require "hecks/hecks/adapters/github_pull_requests/train_sweep"

# A train branch is never reused, so once its pull request is merged or closed the sweep deletes
# it from origin, and keeps the branch of an open pull request or of one not yet settled.
RSpec.describe Hecks::Adapters::GithubPullRequests::TrainSweep do
  let(:now)   { Time.utc(2026, 11, 22, 12) }
  let(:old)   { "2026-11-20T00:00:00Z" }
  let(:fresh) { "2026-11-22T11:50:00Z" }
  let(:refs)  { %w[train/main-aaa train/main-bbb train/main-ccc train/main-ddd train/main-eee train/main-fff] }
  let(:closed) do
    [pull(1, "train/main-aaa", merged: old), pull(2, "train/main-bbb", closed: old),
     pull(4, "train/main-ddd", closed: fresh), pull(5, "train/main-eee", closed: old, state: "closed")]
  end
  let(:open) { [pull(3, "train/main-ccc", state: "open")] }
  let(:calls) { [] }
  let(:failing) { [] }

  def pull(number, branch, merged: nil, closed: merged, state: "closed")
    { "number" => number, "state" => state, "head" => { "ref" => branch, "sha" => "s#{number}" },
      "created_at" => old, "merged_at" => merged, "closed_at" => closed }
  end

  def answer(args)
    path = args.last.to_s
    return refs.map { |ref| { "ref" => "refs/heads/#{ref}" } } if path.include?("matching-refs")
    return closed if path.include?("state=closed")
    return open if path.include?("state=open")

    []
  end

  let(:github) do
    lambda do |*args|
      calls << args
      raise Hecks::Adapters::ConsoleCapture::Failure, "gh api failed: 422" if args.include?("DELETE") && failing.include?(args.last)

      args.include?("DELETE") ? "" : JSON.generate(args.include?("--paginate") ? [answer(args)] : answer(args))
    end
  end

  def sweep = described_class.new(github, ->(_args) { [false, ""] }, now: now).run
  def deleted = calls.select { |call| call.include?("DELETE") }.map { |call| call.last.split("heads/").last }

  it "deletes the branch of a merged pull request and of one closed past the grace period" do
    sweep
    expect(deleted).to contain_exactly("train/main-aaa", "train/main-bbb", "train/main-eee")
  end

  it "keeps the branch of an open pull request, of a recent closure, and of one with none" do
    sweep
    expect(deleted).not_to include("train/main-ccc", "train/main-ddd", "train/main-fff")
  end

  it "names each deletion in its report" do
    expect(sweep).to include("deleted train/main-aaa: #1 merged")
  end

  it "keeps a branch GitHub refuses to delete and still deletes the others" do
    failing << "repos/{owner}/{repo}/git/refs/heads/train/main-aaa"
    expect(sweep).to include(a_string_starting_with("kept train/main-aaa"), "deleted train/main-bbb: #2 closed")
  end

  it "leaves a branch outside the train prefix alone" do
    refs << "train/other-x"
    sweep
    expect(calls.flatten.grep(/matching-refs/)).to all(end_with("heads/train/main-"))
  end
end
