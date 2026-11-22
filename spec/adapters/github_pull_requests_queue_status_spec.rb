require "hecks"
require "json"
require_relative "../../lib/hecks/hecks/adapters/github_pull_requests"

# `ReviewRequest.Status` names where a pull request stands in GitHub's merge queue: queued,
# merging, merged or dropped, from one read of the pull request and its queue timeline.
RSpec.describe "ReviewRequest.Status merge queue standing" do
  subject(:pulls) { Hecks::Adapters::GithubPullRequests.new(runner: runner) }

  let(:view) { { "number" => 7, "state" => "OPEN", "url" => "u", "mergedAt" => nil, "statusCheckRollup" => [] } }
  let(:queue) { { "state" => "OPEN", "mergedAt" => nil, "mergeQueueEntry" => nil, "timelineItems" => { "nodes" => [] } } }
  let(:runner) do
    lambda do |args|
      body = args.first == "api" ? { "data" => { "repository" => { "pullRequest" => queue } } } : view
      [JSON.generate(body), "", true]
    end
  end

  def standing = pulls.status(number: { value: "7" })[:text][/^queue: (.*)$/, 1]

  def event(kind, reason = nil) = { "__typename" => kind, "reason" => reason }

  it "says queued for an entry waiting its turn or its checks", :aggregate_failures do
    queue["mergeQueueEntry"] = { "state" => "AWAITING_CHECKS", "position" => 2 }
    expect(standing).to eq("queued (position 2)")
  end

  it "says merging for an entry GitHub is merging now" do
    queue["mergeQueueEntry"] = { "state" => "LOCKED", "position" => 1 }
    expect(standing).to eq("merging (position 1)")
  end

  it "says merged for a pull request with a merge time" do
    queue["mergedAt"] = "2026-11-22T17:21:13Z"
    expect(standing).to eq("merged")
  end

  it "says dropped for a pull request removed from the queue unmerged" do
    queue["timelineItems"]["nodes"] = [event("AddedToMergeQueueEvent"), event("RemovedFromMergeQueueEvent", "dequeued")]
    expect(standing).to eq("dropped")
  end

  it "says dropped for one removed from the queue and then closed" do
    queue.merge!("state" => "CLOSED", "timelineItems" => { "nodes" => [event("RemovedFromMergeQueueEvent", "dequeued")] })
    expect(standing).to eq("dropped")
  end

  it "says not queued for a pull request never queued" do
    expect(standing).to eq("not queued")
  end

  it "says not queued for one queued again after a removal and now without an entry" do
    queue["timelineItems"]["nodes"] = [event("RemovedFromMergeQueueEvent", "dequeued"), event("AddedToMergeQueueEvent")]
    expect(standing).to eq("not queued")
  end
end
