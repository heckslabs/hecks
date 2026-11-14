require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/main_integration/train"

# A checkout's machine-local overlay is written from the one list of kept aggregates, the
# `KeptAggregate` rows of the Hecks bluebook, so neither the train's copy nor the main checkout
# holds a hand copy that falls behind.
RSpec.describe Hecks::Adapters::MainIntegration::LocalOverlay do
  before(:all) { @rows = Hecks::Adapters::MainIntegration::KeptRows.from_registry(boot_hecks_in_memory.registry) }

  let(:root) { Dir.mktmpdir("local-overlay") }
  let(:file) { File.join(root, described_class::PATH) }

  after { FileUtils.remove_entry(root) }

  def binds(copy)
    described_class.new(root, @rows, copy).text.scan(/^  (\w+)::(\w+)\.persisted_by\("SqlitePersistence"\)$/)
  end

  def listed(copy)
    Hecks::Adapters::MainIntegration::KeptRows.for_copy(@rows, copy).map { |row| [row[:domain], row[:aggregate]] }
  end

  it "binds exactly the rows each copy keeps, the Ticker and the Epic among them", :aggregate_failures do
    expect(binds("main")).to eq(listed("main"))
    expect(binds("train")).to eq(listed("train"))
    expect(binds("main")).to include(%w[Hecks Ticker], %w[Tickets Epic])
  end

  it "binds no aggregate the list leaves out, and nothing of main's alone on the train", :aggregate_failures do
    expect(binds("main")).not_to include(%w[Tickets Adr])
    expect(binds("train").map(&:first).uniq).to eq(%w[Hecks Delivery])
  end

  it "writes once and leaves a current overlay alone", :aggregate_failures do
    described_class.new(root, @rows, "main").write
    expect(described_class.new(root, @rows, "main").write).to be_nil
    expect(File.read(file)).to eq(described_class.new(root, @rows, "main").text)
  end

  it "replaces an overlay that lags the list" do
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, "Hecks.hecksagon \"Hecks\" do\nend\n")
    expect(described_class.new(root, @rows, "train").write).to eq(file)
  end

  it "says what it did through the train" do
    train = Hecks::Adapters::MainIntegration::Train.new(->(*) {}, root: root)
    said = [train.write_overlay(@rows), train.write_overlay(@rows)]
    expect(said).to eq(["wrote the train's overlay #{described_class::PATH}", "train overlay current"])
  end

  it "keeps the train's overlay when no row was read, so nothing is forgotten", :aggregate_failures do
    train = Hecks::Adapters::MainIntegration::Train.new(->(*) {}, root: root)
    expect { train.write_overlay([]) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no kept rows/)
    expect(File.exist?(file)).to be(false)
  end
end
