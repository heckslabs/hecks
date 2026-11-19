require "spec_helper"
require "securerandom"
require_relative "support/fake_train_github"

# A train pull request whose CI failed in exactly one job, with failing specs that touch none of
# the files it changed, has that job rerun once by itself over REST, and is red only when the
# rerun fails too. A related failure, one GitHub cannot relate, or one of two failed jobs is red
# at once. The domain is in Memory and GitHub is a scripted fake.
RSpec.describe "a train pull request's one unrelated failed job" do
  let(:landed) { SecureRandom.hex(20) }
  let(:github) { FakeTrainGithub.new }

  before(:all) { @hecks = boot_hecks_in_memory }

  before do
    Hecks::Adapters::CiRuns.runner = github
    @hecks.registry.event_log.clear
  end

  after { Hecks::Adapters::CiRuns.runner = nil }

  def observe
    Hecks::Runtime::Dispatcher.new(@hecks.registry).dispatch_flat(
      "Hecks::Integration.Observe", run: SecureRandom.uuid, landed: landed
    )
  end

  def names = @hecks.registry.event_log.map(&:name)

  def payload(name) = @hecks.registry.event_log.find { |event| event.name == name }.payload.to_s

  def two_spec_jobs
    [{ name: "rspec shard 1", id: 41, log: FakeTrainGithub::SPEC_LOG, step: "Run specs" },
     { name: "rspec shard 2", id: 42, log: FakeTrainGithub::SPEC_LOG, step: "Run specs" }]
  end

  def exhausted = names.count("TrainPrExhausted")

  def job_rerun = "gh api -X POST repos/{owner}/{repo}/actions/jobs/1/rerun"

  it "reruns the one failed job by itself, over REST, once" do
    observe
    expect([github.job_reruns, github.calls.grep(/run rerun --failed/)]).to eq([[job_rerun], []])
  end

  it "records the rerun with the failing examples, so a spec that keeps flaking is named", :aggregate_failures do
    observe
    expect(payload("TrainPrRerun")).to include("reran job 1 of CI run 77", "examples: spec/real_spec.rb:3")
    expect(exhausted).to eq(0)
  end

  it "is red when the rerun fails too, and never reruns twice" do
    observe
    github.attempt = 2
    observe
    expect([github.reruns.size, exhausted]).to eq([1, 1])
  end

  it "does not rerun a failure whose spec the pull request changed" do
    github.files = ["spec/real_spec.rb"]
    observe
    expect([github.reruns.size, exhausted]).to eq([0, 1])
  end

  it "does not rerun a failure whose spec the changed files map to" do
    github.files = ["lib/hecks/hecks/adapters/ci_runs/relatedness.rb"]
    github.log = "1 examples, 1 failures\nrspec ./spec/hecks_train_pr_single_job_rerun_spec.rb:9 # relates"
    observe
    expect([github.reruns.size, exhausted]).to eq([0, 1])
  end

  it "does not rerun when two jobs failed" do
    github.failed_jobs = two_spec_jobs
    observe
    expect([github.reruns.size, exhausted]).to eq([0, 1])
  end

  it "does not rerun when the pull request's changed files cannot be read", :aggregate_failures do
    github.files = nil
    observe
    expect([github.reruns.size, exhausted]).to eq([0, 1])
    expect(payload("TrainPrFailed")).to include("unknown")
  end

  it "records how many jobs failed and the one job's id as facts" do
    observe
    expect(payload("TrainPrFailed")).to include("spec/real_spec.rb:3")
  end
end
