require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/adapters/driving/resident/crowd"

# The resident cap a launcher judges by (ADR 0201): the Hecks world's `max_residents`, read as
# text so a raised cap works with no resident standing to remember it.
RSpec.describe "the resident cap the world declares" do
  let(:resident) { Hecks::Adapters::Driving::Resident }
  let(:crowd) { resident::Crowd }

  around do |example|
    Dir.mktmpdir("hwc") do |dir|
      @root = File.join(dir, "checkout")
      FileUtils.mkdir_p(File.join(@root, "lib/hecks/hecks"))
      saved = ENV.fetch("HECKS_CACHE_DIR", nil)
      ENV["HECKS_CACHE_DIR"] = File.join(dir, "cache")
      FileUtils.mkdir_p(resident::Paths.directory)
      example.run
    ensure
      ENV["HECKS_CACHE_DIR"] = saved
    end
  end

  def world(name, line)
    File.write(File.join(@root, name), "# resident \"X\", max_residents: 99\n#{line}\n")
  end

  it "lets a raised world cap take effect over a remembered zero" do
    crowd.remember(0)
    world("lib/hecks/hecks/hecks.local.world", 'resident "Launcher", idle_seconds: 600, max_residents: 2')
    expect(crowd.crowded?(@root)).to be(false)
  end

  it "lets a lowered world cap take effect over a remembered higher one" do
    crowd.remember(8)
    world("lib/hecks/hecks/hecks.local.world", 'resident "Launcher", max_residents: 0')
    expect(crowd.crowded?(@root)).to be(true)
  end

  it "prefers the local world to the committed one" do
    world("lib/hecks/hecks/hecks.world", 'resident "Launcher", max_residents: 8')
    world("lib/hecks/hecks/hecks.local.world", 'resident "Launcher", max_residents: 3')
    expect(resident::WorldCap.for(@root)).to eq(3)
  end

  it "reads a local world at the checkout's root" do
    world("hecks.local.world", 'resident "Launcher", max_residents: 4')
    expect(resident::WorldCap.for(@root)).to eq(4)
  end

  it "derives the cap from the machine's profile when no world declares one" do
    allow(Hecks::Adapters::MachineProfiling).to receive(:of).with("residents").and_return(7)
    expect(resident::WorldCap.for(@root)).to eq(7)
  end

  it "falls back to the remembered cap when no world declares one and none can be derived" do
    allow(Hecks::Adapters::MachineProfiling).to receive(:of).with("residents").and_return(nil)
    crowd.remember(5)
    expect(crowd.cap_for(@root)).to eq(5)
  end

  it "reads the cap the committed world declares" do
    real = File.expand_path("..", __dir__)
    expect(resident::WorldCap.for(real)).to be_a(Integer)
  end
end
