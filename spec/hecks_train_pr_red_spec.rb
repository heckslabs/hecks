require "spec_helper"
require "json"
require "securerandom"
require_relative "support/fake_train_github"

# A red train pull request is handled by the pipeline: its failed CI is read through `gh` and recorded,
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
