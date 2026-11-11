require "spec_helper"
require "json"
require "securerandom"
require_relative "support/fake_train_github"

# A red train pull request is handled by the pipeline: its failed CI is read through `gh`, recorded,
# rerun once (twice for a known-flaky spec), and given to a coder as a red-train Work item when the
# reruns fail too. The domain is in Memory and GitHub is a scripted fake.
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

  it "reruns a setup failure twice and files a finding, not a fix item, when it keeps failing" do
    fail_in_setup(3)
    expect([github.reruns.size, names.grep(/WorkPlanned/), names.grep(/StoppedRunReported/).size]).to eq([2, [], 1])
  end

  it "reruns a setup failure that clears and files nothing" do
    fail_in_setup(2)
    expect([github.reruns.size, names.grep(/TrainPrExhausted|WorkPlanned|StoppedRunReported/)]).to eq([2, []])
  end

  it "names the failed step of a setup failure and tells a spec failure from it" do
    fail_in_setup(3)
    expect(@hecks.registry.event_log.map { |e| e.payload.to_s }.join).to include("Install zsh")
  end

  it "records the second attempt's failure and plans the item when GitHub cannot list the jobs", :aggregate_failures do
    github.jobs_error = true
    fail_twice
    expect(names.grep(/TrainPrFailed/).size).to eq(2)
    expect(names).to include("TrainPrExhausted", "WorkPlanned")
  end

  it "observes nothing, and records no failure, when neither the jobs nor the log can be read", :aggregate_failures do
    github.jobs_error = true
    github.log_error = true
    observe
    expect(names).to include("ObserveRefused")
    expect(names).not_to include("TrainPrFailed")
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

  it "reruns a known-flaky spec a second time before it plans" do
    fail_twice("rspec ./spec/bounded_capture_spec.rb:9 # waits")
    expect([github.reruns.size, names.grep(/TrainPrExhausted/)]).to eq([2, []])
  end

  it "does not rerun twice when one failure is observed twice" do
    2.times { observe }
    expect(github.reruns.size).to eq(1)
  end
end
