require "spec_helper"
require "tmpdir"

RSpec.describe Hecks::Bluebook::MetaValidator::SyntaxBoot::DiskCache do
  let(:directory) { Dir.mktmpdir("syntax_boot_cache") }
  let(:host) do
    Object.new.extend(described_class).tap do |object|
      allow(object).to receive_messages(cache_dir: directory, disk_cache_key: "current")
    end
  end
  let(:keep) { described_class::UNREAD_KEEP_SECONDS }

  after { FileUtils.remove_entry(directory) }

  def entry(name, unread_for:)
    path = File.join(directory, "#{name}.marshal")
    File.binwrite(path, Marshal.dump({ keywords: [], arguments: [] }))
    File.utime(Time.now - unread_for, Time.now - unread_for, path)
    path
  end

  it "sweeps a table nobody has read for a day when it writes a new one", :aggregate_failures do
    old = entry("old", unread_for: keep + 60)
    recent = entry("recent", unread_for: 60)
    host.write_disk_cache([], { keywords: [], arguments: [] })

    expect(File.exist?(old)).to be(false)
    expect(File.exist?(recent)).to be(true)
  end

  it "counts a read as a use, so the table in use is never the one swept", :aggregate_failures do
    current = entry("current", unread_for: keep - 60)
    host.read_disk_cache([])
    host.write_disk_cache([], { keywords: [], arguments: [] })

    expect(Time.now - File.mtime(current)).to be < 60
    expect(File.exist?(current)).to be(true)
  end

  describe "a table the gem ships" do
    let(:shipped) { File.join(directory, "prebuilt", "current.marshal") }
    let(:table) { { keywords: [{ name: "shipped" }], arguments: [] } }

    before do
      FileUtils.mkdir_p(File.dirname(shipped))
      File.binwrite(shipped, Marshal.dump(table))
      allow(Hecks::CacheDir).to receive(:prebuilt).with("current.marshal").and_return(shipped)
    end

    it "is read when the user has cached none, and left as it was", :aggregate_failures do
      File.utime(Time.at(0), Time.at(0), shipped)

      expect(host.read_disk_cache([])).to eq(table)
      expect(File.mtime(shipped)).to eq(Time.at(0))
    end

    it "yields to the user's own table" do
      entry("current", unread_for: 60)

      expect(host.read_disk_cache([])).to eq({ keywords: [], arguments: [] })
    end
  end
end
