require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/main_integration/local_overlay"
require "hecks/adapters/driven/sqlite"

# A red episode is decided by the process that verified main and read back by later ones, so it is
# kept in the development checkout's store, not held in the memory of the process that decided it.
# The store here is a file of the example's own; the owner's is never reached.
RSpec.describe "a red episode" do
  before(:context) { @registry = boot_hecks_in_memory.registry }

  around do |example|
    Dir.mktmpdir("hecks-red-episode-") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:aggregate) { @registry.bluebook("Hecks").aggregate("RedEpisode") }

  def overlay(copy)
    rows = Hecks::Adapters::MainIntegration::KeptRows.from_registry(@registry)
    Hecks::Adapters::MainIntegration::LocalOverlay.new(Dir.pwd, rows, copy).text
  end

  # A store opened on the example's file, as a process that has just started opens it.
  def store = Hecks::Adapters::SqlitePersistence.new(aggregate: aggregate, settings: { database: "episodes.db" }, root: @dir)

  def episode(run, culprit)
    Hecks::Runtime::Instance.new(aggregate: aggregate, id: run).tap do |built|
      built[:run] = Hecks::Runtime::Value.for(aggregate, :run, { value: run })
      built[:culprit] = Hecks::Runtime::Value.for(aggregate, :culprit, culprit)
    end
  end

  it "is persisted by the development checkout's overlay" do
    expect(overlay("main")).to include("Hecks::RedEpisode.persisted_by(\"SqlitePersistence\")")
  end

  it "is left in Memory by the train's copy, which decides none" do
    expect(overlay("train")).not_to include("Hecks::RedEpisode")
  end

  it "recorded by one process is read by another", :aggregate_failures do
    store.save(episode("red-1", "abc123"))
    read = store.find("red-1")
    expect(read.id).to eq("red-1")
    expect(read.culprit.value).to eq("abc123")
  end

  it "is listed with the others after a restart" do
    %w[red-1 red-2].each { |run| store.save(episode(run, "abc123")) }
    expect(store.all.map(&:id)).to contain_exactly("red-1", "red-2")
  end
end
