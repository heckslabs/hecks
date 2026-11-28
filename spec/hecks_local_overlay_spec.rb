require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/local_overlaying/local_overlay"

# A checkout's machine-local overlay is written from the one list of kept aggregates, the
# `KeptAggregate` rows of the Hecks bluebook, so no copy holds a hand copy that falls behind.
RSpec.describe Hecks::Adapters::LocalOverlay do
  before(:all) { @rows = Hecks::Adapters::KeptRows.from_registry(boot_hecks_in_memory.registry) }

  let(:root) { Dir.mktmpdir("local-overlay") }
  let(:file) { File.join(root, described_class::PATH) }

  after { FileUtils.remove_entry(root) }

  def binds(copy)
    described_class.new(root, @rows, copy).text.scan(/^  (\w+)::(\w+)\.persisted_by\("SqlitePersistence"\)$/)
  end

  def listed(copy)
    Hecks::Adapters::KeptRows.for_copy(@rows, copy).map { |row| [row[:domain], row[:aggregate]] }
  end

  it "binds exactly the rows each copy keeps, the Operation and the Epic among them", :aggregate_failures do
    expect(binds("main")).to eq(listed("main"))
    expect(binds("train")).to eq(listed("train"))
    expect(binds("main")).to include(%w[Hecks Operation], %w[Tickets Epic])
  end

  it "binds no aggregate the list leaves out, and nothing of main's alone on the train", :aggregate_failures do
    expect(binds("main")).not_to include(%w[Tickets Adr])
    expect(binds("train").map(&:first).uniq).to eq(%w[Hecks])
  end

  it "writes once and leaves a current overlay alone", :aggregate_failures do
    described_class.new(root, @rows, "main").write
    expect(described_class.new(root, @rows, "main").write).to be_nil
    expect(File.read(file)).to eq(described_class.new(root, @rows, "main").text)
  end

  it "renames a finished file into place, so no reader sees an empty overlay", :aggregate_failures do
    allow(File).to receive(:rename).and_call_original
    described_class.new(root, @rows, "main").write
    expect(File).to have_received(:rename).with(/\.\d+\.tmp\z/, file)
    expect(Dir[File.join(File.dirname(file), "*.tmp")]).to be_empty
  end

  it "leaves no temporary file when the rename fails", :aggregate_failures do
    allow(File).to receive(:rename).and_raise(Errno::EACCES)
    expect { described_class.new(root, @rows, "main").write }.to raise_error(Errno::EACCES)
    expect(Dir[File.join(File.dirname(file), "*.tmp")]).to be_empty
  end

  it "refuses to write an overlay that keeps no row, so nothing is forgotten", :aggregate_failures do
    expect { described_class.new(root, [], "main").write }.to raise_error(described_class::Empty, /no kept rows/)
    expect(File.exist?(file)).to be(false)
  end

  it "replaces an overlay that lags the list" do
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, "Hecks.hecksagon \"Hecks\" do\nend\n")
    expect(described_class.new(root, @rows, "train").write).to eq(file)
  end
end
