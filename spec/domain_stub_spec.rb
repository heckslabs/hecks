require "spec_helper"
require "open3"
require "rbconfig"
require "tmpdir"
require "fileutils"
require "hecks/cli/domain_stub"

# The stub files `hecks init` writes (ADR 0087): what each adapter's stub contains, that every
# stub boots and takes its one command, and that the adapter list stays honest.
RSpec.describe Hecks::CLI::DomainStub do
  # Boots a written stub in a child process, so the aggregate constants it installs do not join
  # this process's namespace. A server-backed stub boots on its memory overlay.
  STUB_BOOT = <<~RUBY.freeze
    require "hecks"
    require "hecks/ports/persistence/plugins/era"
    Hecks.boot(ARGV.first, environment: ARGV.last == "overlay" ? "memory" : nil)
    puts "EVENTS=" + Example.create!(name: "first").events.map(&:name).join(",")
  RUBY

  def write_stub(dir, **options)
    described_class.files(name: "Lending", **options).each do |path, text|
      full = File.join(dir, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, text)
    end
  end

  it "names only adapters that the framework declares for the persistence port" do
    declared = Dir.glob(File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/*.adapter")).flat_map do |file|
      File.read(file).scan(/Hecks\.adapter "(\w+)" do\s+port\s+"persistence"/).flatten
    end

    expect(declared).to include(*described_class.adapters)
  end

  it "defaults to an adapter that needs no server, and says which files each one writes" do
    expect(described_class::DEFAULT_ADAPTER).to eq("SqlitePersistence")
    expect(described_class.files(name: "Lending").keys.sort)
      .to eq([".gitignore", "bluebook/lending.bluebook", "bluebook/lending.world"])
    expect(described_class.files(name: "Lending", adapter: "Memory").keys.sort)
      .to eq(["bluebook/lending.bluebook", "bluebook/lending.world"])
    expect(described_class.files(name: "Lending", adapter: "Postgres").keys.sort)
      .to eq(["bluebook/environments/memory.world", "bluebook/lending.bluebook", "bluebook/lending.world"])
  end

  it "binds the world to the chosen adapter" do
    world = described_class.files(name: "Lending", adapter: "SqlitePersistence").fetch("bluebook/lending.world")

    expect(world).to include('default_adapter "SqlitePersistence"', 'default_database "data/lending.db"')
  end

  it "refuses a name that is not a capitalised word, and an adapter it does not know" do
    expect { described_class.files(name: "lending") }.to raise_error(ArgumentError, /not a domain name/)
    expect { described_class.files(name: "Lending", adapter: "Nope") }
      .to raise_error(ArgumentError, /unknown adapter "Nope"; choose one of Memory, SqlitePersistence/)
  end

  described_class.adapters.each do |adapter|
    it "boots the #{adapter} stub and runs its creating command" do
      Dir.mktmpdir do |dir|
        write_stub(dir, adapter: adapter)
        server = File.exist?(File.join(dir, "bluebook/environments/memory.world"))
        out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", STUB_BOOT, dir, server ? "overlay" : "none",
                                          chdir: InMemoryDomain::ROOT)

        expect(status).to be_success, err
        expect(out).to include("EVENTS=ExampleCreated")
      end
    end
  end
end
