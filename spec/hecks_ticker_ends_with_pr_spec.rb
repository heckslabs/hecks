require "spec_helper"
require "securerandom"
require_relative "support/ticker_chain"
require_relative "support/fake_train_github"

# The chain of ticks for a train pull request ends when the pull request does: it failed past its
# reruns and a coder was given the fix, or it was closed. The next tick is then refused and the
# ending is recorded as `TickerStopped`. GitHub is a scripted fake and the domain is in Memory.
RSpec.describe "the chain of ticks ends with its train pull request" do
  include TickerChain

  let(:landed) { SecureRandom.hex(20) }
  let(:github) { FakeTrainGithub.new }

  before(:all) { @hecks = boot_hecks_in_memory }

  before do
    Hecks::Adapters::CiRuns.runner = github
    @hecks.registry.event_log.clear
    start(landed)
  end

  after { Hecks::Adapters::CiRuns.runner = nil }

  def observe
    dispatch("Integration.Observe", run: SecureRandom.uuid, landed: landed)
  end

  def fail_past_reruns
    github.log = FakeTrainGithub::SPEC_LOG
    [1, 2].each do |attempt|
      github.attempt = attempt
      observe
    end
  end

  def stopped = @hecks.registry.event_log.select { |event| event.name == "TickerStopped" }

  it "stops the chain when the pull request failed past its reruns", :aggregate_failures do
    fail_past_reruns
    expect(stopped.size).to eq(1)
    expect { tick(landed, 1) }.to raise_error(StandardError)
  end

  it "keeps the chain while a rerun may still clear the pull request" do
    github.attempt = 1
    observe
    expect(stopped).to be_empty
  end

  it "stops the chain when the pull request was closed, saying why", :aggregate_failures do
    github.state = "CLOSED"
    observe
    expect(stopped.size).to eq(1)
    expect(stopped.first.payload.to_s).to include("closed without merging")
  end
end
