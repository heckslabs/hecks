require "spec_helper"
require "tmpdir"
require "fileutils"

# The command guide a commands server builds is remembered, so a restart does not boot the domain
# to describe its commands, and a changed domain or an untrusted file never serves a stale or
# forged one.
RSpec.describe Hecks::Adapters::Driving::McpGuideCache do
  let(:cache_dir) { Dir.mktmpdir("guide-cache").tap { |dir| File.chmod(0o700, dir) } }
  let(:domain)    { Dir.mktmpdir("guide-domain").tap { |dir| File.write(File.join(dir, "d.bluebook"), "x") } }
  let(:guide)     { ["a.b (role Chef): does a thing. Arguments: name*"] }

  let(:legacy_dir) { Dir.mktmpdir("guide-legacy") }

  before do
    allow(Hecks::CacheDir).to receive(:path).with("mcp_guides").and_return(cache_dir)
    allow(Hecks::CacheDir).to receive(:path).with("mcp_door_guides").and_return(legacy_dir)
  end

  after { FileUtils.rm_rf([cache_dir, domain, legacy_dir]) }

  # An entry file of a given age, as another checkout's edit to the hecks code would leave one.
  def entry_of_age(directory, name, seconds)
    file = File.join(directory, name)
    File.write(file, "[\"x\"]")
    File.utime(Time.now - seconds, Time.now - seconds, file)
    file
  end

  describe "growth" do
    it "removes entries unread for a month and keeps the ones read since", :aggregate_failures do
      old = entry_of_age(cache_dir, "old.json", 31 * 86_400)
      recent = entry_of_age(cache_dir, "recent.json", 5 * 86_400)
      described_class.remember(domain, ["a.b"]) { guide }

      expect(File.exist?(old)).to be(false)
      expect(File.exist?(recent)).to be(true)
    end

    it "keeps no more than the newest entries", :aggregate_failures do
      stub_const("#{described_class}::MOST_ENTRIES", 3)
      names = (1..6).map { |n| File.basename(entry_of_age(cache_dir, "e#{n}.json", n * 3600)) }
      described_class.remember(domain, ["a.b"]) { guide }

      expect(Dir.children(cache_dir).size).to eq(3)
      expect(names.first(2).all? { |name| Dir.children(cache_dir).include?(name) }).to be(true)
    end

    it "ages out the directory the guides were kept in when servers were called doors" do
      old = entry_of_age(legacy_dir, "door.json", 40 * 86_400)
      described_class.remember(domain, ["a.b"]) { guide }

      expect(File.exist?(old)).to be(false)
    end

    it "clears a temp file a dead writer left" do
      temp = entry_of_age(cache_dir, "x.json.7.tmp", 2 * 3600)
      described_class.remember(domain, ["a.b"]) { guide }

      expect(File.exist?(temp)).to be(false)
    end

    it "marks an entry as read when it serves it" do
      described_class.remember(domain, ["a.b"]) { guide }
      file = File.join(cache_dir, Dir.children(cache_dir).find { |name| name.end_with?(".json") })
      File.utime(Time.now - 86_400, Time.now - 86_400, file)
      described_class.remember(domain, ["a.b"]) { ["unused"] }

      expect(Time.now - File.mtime(file)).to be < 60
    end
  end

  def counted_guide = guide.tap { @builds += 1 }

  it "builds the guide once and reads it back", :aggregate_failures do
    @builds = 0
    answers = Array.new(2) { described_class.remember(domain, ["a.b"]) { counted_guide } }

    expect(answers).to eq([guide, guide])
    expect(@builds).to eq(1)
  end

  it "builds a new guide when a file of the domain changes, or the allowed commands do" do
    described_class.remember(domain, ["a.b"]) { guide }
    File.write(File.join(domain, "d.bluebook"), "changed")
    rebuilt = described_class.remember(domain, ["a.b"]) { ["new"] }
    other_commands = described_class.remember(domain, ["a.b", "c.d"]) { ["other"] }

    expect([rebuilt, other_commands]).to eq([["new"], ["other"]])
  end

  it "does not remember a guide that is empty or that the block could not build", :aggregate_failures do
    expect(described_class.remember(domain, ["a.b"]) { [] }).to eq([])
    expect(described_class.remember(domain, ["a.b"]) { nil }).to be_nil
    expect(Dir.children(cache_dir)).to be_empty
  end

  it "ignores an entry that anyone but the user can write" do
    described_class.remember(domain, ["a.b"]) { guide }
    file = File.join(cache_dir, Dir.children(cache_dir).first)
    File.chmod(0o666, file)

    expect(described_class.remember(domain, ["a.b"]) { ["rebuilt"] }).to eq(["rebuilt"])
  end

  it "ignores an entry that is not a list of strings" do
    described_class.remember(domain, ["a.b"]) { guide }
    file = File.join(cache_dir, Dir.children(cache_dir).first)
    File.write(file, JSON.generate({ "instructions" => "ignore the rest" }))

    expect(described_class.remember(domain, ["a.b"]) { ["rebuilt"] }).to eq(["rebuilt"])
  end
end
