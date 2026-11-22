# frozen_string_literal: true

require "spec_helper"
require "securerandom"
require "hecks/hecks/adapters/ci_runs"
require "hecks/hecks/adapters/github_pull_requests"
require_relative "support/fake_dropped_github"
require_relative "support/stall_watch_looks"

# A train pull request the merge queue dropped when main moved (open, every check green, its
# auto-merge gone) is enqueued again by the pipeline. One that no longer merges cleanly parks its
# run, so verifying it again rebuilds it on the new tip. Each beat is a process of its own.
RSpec.describe "a train pull request the merge queue dropped" do
  include_context "with a stall watch tap"

  let(:landed) { SecureRandom.hex(20) }
  let(:github) { FakeDroppedGithub.new }

  before do
    Hecks::Adapters::CiRuns.runner = github
    Hecks::Adapters::GithubPullRequests.runner = github.method(:gh)
    File.write(tap, "")
  end

  after do
    Hecks::Adapters::CiRuns.runner = nil
    Hecks::Adapters::GithubPullRequests.runner = nil
  end

  def beat
    store("TrainPrEnqueue").reset!
    Hecks::Adapters::CiRuns::PullCache.shared.clear
    dispatch("Hecks::Integration.Observe", run: SecureRandom.uuid, landed: landed)
  end

  def store(name) = registry.repository("Hecks", registry.bluebook("Hecks").aggregate(name))

  def names = registry.event_log.map(&:name)

  it "enqueues it again with auto-merge", :aggregate_failures do
    beat
    expect(github.merges).to eq(["gh pr merge #{github.number} --auto --merge"])
    expect(names).to include("TrainPrEnqueueRequested", "ArmAnswered", "TrainPrEnqueued")
  end

  it "enqueues it again each time main moves under it" do
    2.times { beat }
    expect(github.merges.size).to eq(2)
  end

  it "leaves a pull request that still holds auto-merge alone" do
    github.auto_merge = { enabled_by: "x" }
    beat
    expect(github.merges).to be_empty
  end

  it "leaves a pull request with a check still running alone" do
    github.rollup = [{ name: "ci", status: "IN_PROGRESS", conclusion: "" }]
    beat
    expect(github.merges).to be_empty
  end

  it "parks the run of one that no longer merges cleanly instead of enqueueing it", :aggregate_failures do
    github.merge_state = "dirty"
    beat
    expect(github.merges).to be_empty
    expect(names).to include("PullRequestClosed")
  end

  it "waits when GitHub has not yet computed its mergeability", :aggregate_failures do
    github.merge_state = "unknown"
    beat
    expect(github.merges).to be_empty
    expect(names).not_to include("PullRequestClosed")
  end

  it "records a refused enqueue and keeps the run watched", :aggregate_failures do
    github.merge_refusal = "Pull request is in clean status"
    beat
    expect(names).to include("ArmRefused", "TrainPrEnqueueDeclined")
    expect(names).not_to include("PullRequestClosed")
  end
end
