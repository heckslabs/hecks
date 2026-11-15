require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/main_integration/local_world"

# The push train's copy reads the owner's local world, so a wake session started there sees the
# owner's stores. Every checkout here is a temporary directory; no live world is read.
RSpec.describe Hecks::Adapters::MainIntegration::LocalWorld do
  let(:main) { Dir.mktmpdir("owner") }
  let(:train) { Dir.mktmpdir("train") }
  let(:source) { File.join(main, described_class::PATH) }
  let(:link) { File.join(train, described_class::PATH) }

  after { [main, train].each { |dir| FileUtils.remove_entry(dir) } }

  def world(text = "Hecks.world \"Tickets\" do\n  persisted_by(\"Sqlite\") do\n    database \"/x/tickets.db\"\n  end\nend\n")
    FileUtils.mkdir_p(File.dirname(source))
    File.write(source, text)
  end

  def sync = described_class.new(train, main).sync

  it "links the train's world to the owner's, which a session there reads", :aggregate_failures do
    world
    sync
    expect(File.readlink(link)).to eq(source)
    expect(File.read(link)).to include("database \"/x/tickets.db\"")
  end

  it "replaces a world of the train's own with the link" do
    world
    FileUtils.mkdir_p(File.dirname(link))
    File.write(link, "# stale\n")
    sync
    expect(File.symlink?(link)).to be(true)
  end

  it "leaves a correct link alone", :aggregate_failures do
    world
    sync
    expect(sync).to eq("train world current")
    expect(File.readlink(link)).to eq(source)
  end

  it "does nothing when the owner has no world" do
    expect(sync).to eq("no owner world to read")
  end

  it "removes a link, and names why, when the owner's world gains mint_eras", :aggregate_failures do
    world
    sync
    world("Hecks.world \"Hecks\" do\n  persisted_by(\"PostgresEra\") do\n    mint_eras true\n  end\nend\n")
    expect(sync).to include("not linked")
    expect(File.symlink?(link)).to be(false)
  end

  it "never links a world that archives a ledger" do
    world("Hecks.world \"Hecks\" do\n  persisted_by(\"X\") do\n    disposable_ledger true\n  end\nend\n")
    sync
    expect(File.exist?(link)).to be(false)
  end
end
