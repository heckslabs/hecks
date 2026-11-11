require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/main_integration/train"

# The push train's copy has a machine-local overlay of its own; it is written from the one list of
# aggregates the train needs kept, so the clock chain's Ticker is persisted there as the rest are.
RSpec.describe Hecks::Adapters::MainIntegration::TrainOverlay do
  let(:root) { Dir.mktmpdir("train-overlay") }
  let(:file) { File.join(root, described_class::PATH) }

  after { FileUtils.remove_entry(root) }

  it "persists every aggregate the list names, the Ticker among them", :aggregate_failures do
    described_class.new(root).write
    expect(File.read(file)).to include("Hecks::Ticker.persisted_by(\"SqlitePersistence\")")
    expect(File.read(file).scan("persisted_by(\"SqlitePersistence\")").size).to eq(described_class::PERSISTED.size)
  end

  it "writes once and leaves a current overlay alone", :aggregate_failures do
    described_class.new(root).write
    expect(described_class.new(root).write).to be_nil
    expect(File.read(file)).to eq(described_class.new(root).text)
  end

  it "replaces an overlay that lags the list" do
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, "Hecks.hecksagon \"Hecks\" do\nend\n")
    expect(described_class.new(root).write).to eq(file)
  end

  it "says what it did through the train" do
    train = Hecks::Adapters::MainIntegration::Train.new(->(*) {}, root: root)
    said = [train.write_overlay, train.write_overlay]
    expect(said).to eq(["wrote the train's overlay #{described_class::PATH}", "train overlay current"])
  end
end
