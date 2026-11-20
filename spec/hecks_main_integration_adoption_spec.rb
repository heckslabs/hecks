require "spec_helper"
require "hecks/hecks/adapters/main_integration"
require_relative "support/red_train_repository"

# The run opened for a tip of local main no run covers, while an older run's train pull request
# is still watched: a red one with no check left running does not hold the line, so the tip that
# reverts its bad landing is opened; one still running does. The repository is a throwaway one,
# and the registry, GitHub and the dispatcher are stand-ins.
RSpec.describe Hecks::Adapters::MainIntegration::Adoption do
  include RedTrainRepository

  let(:dir) { File.realpath(Dir.mktmpdir("hecks-adoption")) }
  let(:repo) { File.join(dir, "main") }
  let(:registry) { Struct.new(:saga_instances).new({ "MainIntegration" => { @watched => watched_run } }) }
  let(:dispatcher) { instance_double(Hecks::Runtime::Dispatcher, dispatch_flat: nil) }
  let(:checks) { instance_double(Hecks::Adapters::MainIntegration::TrainChecks) }

  before do
    open_repository
    @watched = land("one")
    land("two")
    Hecks::Adapters::MainIntegration::BoardedCheck.runner = ->(_argv, chdir:) { [true, chdir && "[]"] }
    allow(Hecks::Runtime::Dispatcher).to receive(:new).and_return(dispatcher)
    allow(Hecks::Adapters::MainIntegration::TrainChecks).to receive(:new).and_return(checks)
  end

  after do
    Hecks::Adapters::MainIntegration::BoardedCheck.runner = nil
    FileUtils.remove_entry(dir)
  end

  def watched_run = { state: "ci_running", memory: { checkout: repo } }

  it "opens a run for the tip when the watched train pull request is red and holds no line" do
    allow(checks).to receive(:blocking).and_return(nil)
    expect(described_class.new(registry).open_run.first).to include("#{head[0, 10]} is ahead of origin/main with no run")
  end

  it "records the tip as landed on main, which starts its run" do
    allow(checks).to receive(:blocking).and_return(nil)
    described_class.new(registry).open_run
    expect(dispatcher).to have_received(:dispatch_flat).with("Delivery::Landing.Adopt", hash_including(landed: head))
  end

  it "opens nothing while the watched train pull request still holds the line" do
    allow(checks).to receive(:blocking).and_return([:run, nil])
    expect(described_class.new(registry).open_run).to eq([])
  end
end
