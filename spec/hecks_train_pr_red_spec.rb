require "spec_helper"
require "json"
require "securerandom"
require_relative "support/fake_train_github"

# A red train pull request is handled by the pipeline: its failed CI is read through `gh`, recorded,
# its one unrelated failed job rerun once by itself, and searched for the landing that broke it when
# the rerun fails too; here the boarded commit is in no repository, so the search cannot run and the
# failure is given to a coder as a red-train Work item. The domain is in Memory and GitHub is a
# scripted fake.
RSpec.describe "a red train pull request" do
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

  def fail_twice(log = nil)
    github.log = log if log
    observe
    github.attempt = 2
    observe
  end

  def fail_in_setup(times)
    github.log = FakeTrainGithub::SETUP_LOG
    (1..times).each do |attempt|
      github.attempt = attempt
      observe
    end
  end

  def mixed_jobs
    [{ name: "rspec zsh", id: 11, log: FakeTrainGithub::SETUP_LOG, step: "Install zsh" },
     { name: "rspec shard 3", id: 12, log: FakeTrainGithub::SPEC_LOG, step: "Run specs" }]
  end

  def fail_mixed
    github.failed_jobs = mixed_jobs
    fail_twice
  end

  it "plans a red item naming the spec when a setup job and a spec job failed together", :aggregate_failures do
    fail_mixed
    expect(names).to include("WorkPlanned")
    expect(@hecks.registry.event_log.map { |e| e.payload.to_s }.join).to include("spec/real_spec.rb")
  end

  it "reads each failed job's own log, one call per job" do
    github.failed_jobs = mixed_jobs
    observe
    expect(github.calls.grep(/--job \d+ --log-failed/).size).to eq(2)
  end

  it "reruns a setup failure once and files a finding, not a fix item, when it fails again" do
    fail_in_setup(2)
    expect([github.reruns.size, names.grep(/WorkPlanned/), names.grep(/StoppedRunReported/).size]).to eq([1, [], 1])
  end

  it "reruns a setup failure that clears and files nothing" do
    fail_in_setup(1)
    expect([github.reruns.size, names.grep(/TrainPrExhausted|WorkPlanned|StoppedRunReported/)]).to eq([1, []])
  end

  it "names the failed step of a setup failure and tells a spec failure from it" do
    fail_in_setup(2)
    expect(@hecks.registry.event_log.map { |e| e.payload.to_s }.join).to include("Install zsh")
  end

  it "records the second attempt's failure and plans the item when GitHub cannot list the jobs", :aggregate_failures do
    github.jobs_error = true
    fail_twice
    expect(names.grep(/TrainPrFailed/).size).to eq(2)
    expect(names).to include("TrainPrExhausted", "WorkPlanned")
  end

  it "watches on, and records no failure, when neither the jobs nor the log can be read", :aggregate_failures do
    github.jobs_error = true
    github.log_error = true
    observe
    expect(names).to include("ObserveAnswered")
    expect(names).not_to include("TrainPrFailed", "ObserveRefused")
  end

  def observe_unreadable_then_readable
    github.jobs_error = github.log_error = true
    observe
    github.jobs_error = github.log_error = false
    observe
  end

  it "records the failure once when a later observation can read it" do
    observe_unreadable_then_readable
    expect(names.grep(/TrainPrFailed/).size).to eq(1)
  end

  it "does not read a pull request with a check still running as failed", :aggregate_failures do
    github.rollup = [{ name: "rspec", status: "COMPLETED", conclusion: "FAILURE" },
                     { name: "rspec 2", status: "IN_PROGRESS", conclusion: "" }]
    observe
    expect(names).not_to include("TrainPrFailed", "ObserveRefused")
  end

  it "reruns a failure once and plans nothing while the rerun is out" do
    observe
    expect([github.reruns.size, names.grep(/TrainPrExhausted/)]).to eq([1, []])
  end

  it "records the failure and the rerun as events" do
    observe
    expect(names).to include("TrainPrFailed", "TrainPrRerun")
  end

  it "plans one red item when the rerun fails too" do
    fail_twice
    expect([github.reruns.size, names.grep(/TrainPrExhausted/).size]).to eq([1, 1])
  end

  it "plans the item wanted now" do
    fail_twice
    expect(names).to include("WorkPlanned", "WorkPrioritized")
  end

  it "never reruns a spec failure twice, whichever spec it names" do
    fail_twice("rspec ./spec/bounded_capture_spec.rb:9 # waits")
    expect([github.reruns.size, names.grep(/TrainPrExhausted/).size]).to eq([1, 1])
  end

  it "does not rerun twice when one failure is observed twice" do
    2.times { observe }
    expect(github.reruns.size).to eq(1)
  end

  def rerun_payload = @hecks.registry.event_log.find { |e| e.name == "TrainPrRerun" }.payload.to_s

  it "names the failed steps of the jobs in a setup rerun's record", :aggregate_failures do
    fail_in_setup(1)
    expect(rerun_payload).to include("failed steps: rspec shard 1/Install zsh")
    expect(github.reruns).to eq(["gh run rerun --failed 77"])
  end

  it "leaves the rerun report as it was when no step is named" do
    expect(Hecks::Adapters::CiRuns.new.restart(ci_run: "77", pr: "5")[:report][:value])
      .to eq("reran the failed jobs of CI run 77 (PR 5)")
  end
end
