require "spec_helper"
require "securerandom"
require_relative "support/fake_unstarted_github"
require_relative "support/stall_watch_looks"

# A train pull request whose CI never started (no check listed, its run queued, as in an Actions
# outage) is noticed by the pipeline: past ten minutes it is a `ci-not-started` stall, filed once,
# and past twenty it is closed and reopened once, which starts its CI again. A pull request with
# checks is never touched. Each beat is a process of its own, so only the tap and GitHub remember.
RSpec.describe "a train pull request whose CI never started" do
  include_context "with a stall watch tap"

  let(:landed) { SecureRandom.hex(20) }
  let(:github) { FakeUnstartedGithub.new }

  before do
    Hecks::Adapters::CiRuns.runner = github
    Hecks::Adapters::GithubPullRequests.runner = github.method(:gh)
    File.write(tap, "")
  end

  after do
    Hecks::Adapters::CiRuns.runner = nil
    Hecks::Adapters::GithubPullRequests.runner = nil
  end

  # One beat in a process of its own: the train pull request is read, what that emitted is written
  # to the tap as the live tap would, and the stall watch looks.
  def beat
    %w[TrainPrCi TrainPrReopen Stall].each { |name| store(name).reset! }
    tapped { dispatch("Hecks::Integration.Observe", run: SecureRandom.uuid, landed: landed) }
    tapped { detect("look-#{SecureRandom.hex(4)}") }
  end

  def store(name) = registry.repository("Hecks", registry.bluebook("Hecks").aggregate(name))

  def tapped
    before = registry.event_log.size
    yield
    registry.event_log.drop(before).each { |event| append_tap(event.name, event.id.to_s, event.aggregate.to_s) }
  end

  def payloads(name) = registry.event_log.select { |event| event.name == name }.map { |event| event.payload.to_s }

  it "files one stall over two beats once its CI has waited past ten minutes" do
    2.times { beat }
    expect(events_named("StallFiled")).to eq(1)
  end

  it "names the pull request and its queued run in the stall", :aggregate_failures do
    beat
    expect(payloads("StallFiled").join).to include(github.number.to_s)
    expect(payloads("TrainPrCiAwaited").join).to include("queued", "no check results")
  end

  it "files nothing and touches nothing under ten minutes", :aggregate_failures do
    github.opened = 5
    beat
    expect(events_named("TrainPrCiAwaited") + events_named("StallFiled")).to eq(0)
    expect(github.touched).to be_empty
  end

  it "does not reopen it between ten and twenty minutes" do
    beat
    expect(github.touched).to be_empty
  end

  it "closes and reopens it exactly once past twenty minutes, over two beats", :aggregate_failures do
    github.opened = 25
    2.times { beat }
    expect([github.closed.size, github.reopens.size]).to eq([1, 1])
    expect(names_of_reopen).to eq(%w[TrainPrReopenRequested CycleAnswered TrainPrReopened])
  end

  def names_of_reopen = registry.event_log.map(&:name).grep(/TrainPrReopen|CycleAnswered|CycleRefused/)

  it "turns auto-merge on again after the reopen" do
    github.opened = 25
    beat
    expect(github.calls.grep(/pr merge \d+ --auto --squash/).size).to eq(1)
  end

  it "never touches a pull request with checks, nor files a stall for it", :aggregate_failures do
    github.opened = 25
    github.rollup = [{ name: "rspec", status: "IN_PROGRESS", conclusion: "" }]
    beat
    expect(github.touched).to be_empty
    expect(events_named("StallFiled")).to eq(0)
  end

  it "keeps the run watched while the pull request is closed for its reopening", :aggregate_failures do
    github.state = "CLOSED"
    github.comments = [{ body: Hecks::Adapters::CiRuns::ReopenMarker::REOPENING }]
    beat
    expect(registry.event_log.map(&:name)).not_to include("PullRequestClosed")
  end
end
