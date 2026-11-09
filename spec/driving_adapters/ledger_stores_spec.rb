require "spec_helper"
require "tmpdir"
require "fileutils"

# The store rows a worktree's write is judged by. The main checkout's launcher is a stand-in here:
# nothing runs, and no cache outside a temporary directory is touched.
RSpec.describe Hecks::Adapters::Driving::LedgerStores do
  around do |example|
    Dir.mktmpdir do |root|
      @root = File.realpath(root)
      example.run
    end
  end

  let(:reported) do
    ["environment: none (default)", "store Tickets: Memory (attaching domain's root default)",
     "store Tickets::Work: SqliteAt /x/tickets.db (aggregate bind in the hecksagon)", "cache directory: /y (default)"].join("\n")
  end

  def main = File.join(@root, "main")

  def cache = File.join(@root, "cache")

  def launches = @launches ||= []

  def launch(text = reported, success: true)
    lambda do |launcher, args, directory|
      launches << [launcher, args, directory]
      [text, success]
    end
  end

  def rows(text = reported, **given)
    described_class.main_rows(main, cache: cache, launch: launch(text, **given))
  end

  before do
    FileUtils.mkdir_p([File.join(main, "lib/hecks/hecks"), File.join(main, "exe")])
    File.write(File.join(main, "lib/hecks/hecks/hecks.local.hecksagon"), "a")
  end

  it "reads the store rows main's own launcher reports, and no other line" do
    expect(rows.map(&:first)).to eq(["store Tickets", "store Tickets::Work"])
  end

  it "splits a row into its label, the store and where it was declared" do
    expect(rows.last).to eq(["store Tickets::Work", "SqliteAt /x/tickets.db", "aggregate bind in the hecksagon"])
  end

  it "asks main's launcher about main's Hecks domain, in main" do
    rows

    expect(launches.first).to eq([File.join(main, "exe/hecks"), ["config", "domain.value=#{main}/lib/hecks/hecks"], main])
  end

  it "keeps the rows while the declaration files are unchanged" do
    2.times { rows }

    expect(launches.size).to eq(1)
  end

  it "asks again when a declaration file changes" do
    rows
    File.write(File.join(main, "lib/hecks/hecks/hecks.local.hecksagon"), "a longer file")
    rows

    expect(launches.size).to eq(2)
  end

  it "fails closed when the launcher fails, and keeps nothing", :aggregate_failures do
    expect { rows(success: false) }.to raise_error(described_class::Unreadable, /did not report its stores/)
    expect(Dir.glob(File.join(cache, "*"))).to be_empty
  end

  it "fails closed when the launcher reports no store rows" do
    expect { rows("environment: none (default)") }.to raise_error(described_class::Unreadable)
  end

  it "answers the runtime's rows for the worktree and main's for the main checkout", :aggregate_failures do
    allow(described_class).to receive(:registry_rows).and_return([["store Tickets", "Memory", "x"]])
    runtime = instance_double(Hecks::Runtime::Dispatcher, registry: :registry)
    stores = described_class.for_runtime(runtime, "/wt", cache: cache, launch: launch)

    expect(stores.call("/wt")).to eq([["store Tickets", "Memory", "x"]])
    expect(stores.call(main).map(&:first)).to include("store Tickets::Work")
  end
end
