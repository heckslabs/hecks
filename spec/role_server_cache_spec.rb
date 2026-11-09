require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/role_server_cache"

# What a role's MCP server reads at startup to learn the commands its routing rows name, without
# loading the framework. The file is named for the checkout's bluebooks, so an edit to a routing row
# or a command misses, and it counts only when this user owns it and nobody else can write it.
RSpec.describe Hecks::RoleServerCache do
  let(:home)     { Dir.mktmpdir("role-cache-home") }
  let(:checkout) { Dir.mktmpdir("role-cache-checkout") }

  before do
    @saved = ENV.values_at("XDG_CACHE_HOME", "HOME")
    ENV["XDG_CACHE_HOME"] = home
    Hecks::CacheDir.reset!
    build_checkout
  end

  after do
    ENV["XDG_CACHE_HOME"], ENV["HOME"] = @saved
    Hecks::CacheDir.reset!
    FileUtils.remove_entry(home)
    FileUtils.remove_entry(checkout)
  end

  def build_checkout
    { "lib/hecks/agents/agents.bluebook" => "rows v1", "lib/hecks/hecks/commands.bluebook" => "commands v1",
      "lib/hecks/version.rb" => "VERSION = 1" }.each do |name, text|
      FileUtils.mkdir_p(File.dirname(File.join(checkout, name)))
      File.write(File.join(checkout, name), text)
    end
  end

  def edit(name, text) = File.write(File.join(checkout, name), text)

  def written = described_class.write(checkout, { "orchestrator" => ["dispatch.fill"], "closed" => [] })

  it "misses until a table is written for this state" do
    expect(described_class.lookup(checkout, "orchestrator")).to eq(:miss)
  end

  it "answers the commands a role's rows name" do
    written

    expect(described_class.lookup(checkout, "orchestrator")).to eq(["dispatch.fill"])
  end

  it "answers an empty list for a role whose rows name no command, which is not permission" do
    written

    expect(described_class.lookup(checkout, "closed")).to eq([])
  end

  it "answers unrestricted for a role with no rows" do
    written

    expect(described_class.lookup(checkout, "coder")).to eq(:unrestricted)
  end

  it "answers unrestricted for a checkout with no agents bluebook" do
    FileUtils.rm(File.join(checkout, "lib/hecks/agents/agents.bluebook"))

    expect(described_class.lookup(checkout, "orchestrator")).to eq(:unrestricted)
  end

  it "does not reuse a table after the agents bluebook changes" do
    written
    edit("lib/hecks/agents/agents.bluebook", "rows v2")

    expect(described_class.lookup(checkout, "orchestrator")).to eq(:miss)
  end

  it "does not reuse a table after a command bluebook changes" do
    written
    edit("lib/hecks/hecks/commands.bluebook", "commands v2")

    expect(described_class.lookup(checkout, "orchestrator")).to eq(:miss)
  end

  it "does not reuse a table after the version file changes" do
    written
    edit("lib/hecks/version.rb", "VERSION = 2")

    expect(described_class.lookup(checkout, "orchestrator")).to eq(:miss)
  end

  it "does not trust a file other users can write" do
    File.chmod(0o666, written)

    expect(described_class.lookup(checkout, "orchestrator")).to eq(:miss)
  end

  it "reads a file that is not a table as a miss" do
    File.write(written, "not json")

    expect(described_class.lookup(checkout, "orchestrator")).to eq(:miss)
  end

  it "writes a file only its owner can read" do
    expect(File.stat(written).mode & 0o777).to eq(0o600)
  end

  it "keeps the newest files only" do
    (described_class::KEEP + 3).times do |n|
      edit("lib/hecks/hecks/commands.bluebook", "commands #{n}")
      written
    end

    expect(Dir.glob(File.join(Hecks::CacheDir.path(described_class::DIRECTORY), "*.json")).size).to eq(described_class::KEEP)
  end
end
