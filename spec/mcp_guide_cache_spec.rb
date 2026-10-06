require "spec_helper"
require "tmpdir"
require "fileutils"

# The command guide a commands door builds is remembered, so a restart does not boot the domain
# to describe its commands, and a changed domain or an untrusted file never serves a stale or
# forged one.
RSpec.describe Hecks::Doors::McpGuideCache do
  let(:cache_dir) { Dir.mktmpdir("guide-cache").tap { |dir| File.chmod(0o700, dir) } }
  let(:domain)    { Dir.mktmpdir("guide-domain").tap { |dir| File.write(File.join(dir, "d.bluebook"), "x") } }
  let(:guide)     { ["a.b (role Chef): does a thing. Arguments: name*"] }

  before { allow(Hecks::CacheDir).to receive(:path).with("mcp_door_guides").and_return(cache_dir) }

  after { FileUtils.rm_rf([cache_dir, domain]) }

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
