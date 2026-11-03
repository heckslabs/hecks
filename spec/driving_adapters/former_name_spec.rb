require "spec_helper"
require "tmpdir"

# An aggregate renamed with `formerly_known_as` keeps the rows it wrote under its former name,
# and the launcher still answers the former spelling, with a note once on standard error.
RSpec.describe "a renamed aggregate's former name" do
  around do |example|
    @dir = Dir.mktmpdir("hecks-former-name-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  let(:sqlite_adapter) { File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/sqlite.adapter") }
  let(:fixture) { File.join(@dir, "ledger.bluebook") }

  # A ledger whose entry aggregate carries the name `name`, with an optional former name `former`.
  def source(name, former = nil)
    keeps = former ? %(formerly_known_as "#{former}") : ""
    "Hecks.bluebook \"Ledger\" do\n  aggregate \"#{name}\" do\n    #{keeps}\n#{ENTRY}  end\nend\n"
  end

  # The entry aggregate's declarations: its identity, its fields and its one command.
  ENTRY = <<~RUBY.gsub(/^/, "    ")
    identified_by :run
    attribute :run, RunKey
    attribute :label, Text

    value_object "RunKey" do
      attribute :value, String
    end

    value_object "Text" do
      attribute :value, String
    end

    command "Post" do
      attribute :run, RunKey
      attribute :label, Text
    end
  RUBY

  # Boots the ledger from `fixture` against the SQLite file in the temp directory.
  def boot
    registry = Hecks::Runtime::Registry.new(root: @dir)
    Hecks.with_registry(registry) { declare }
    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def declare
    Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
    Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
    Kernel.load(sqlite_adapter)
    Kernel.load(fixture)
    Hecks.hecksagon("Ledger") { persisted_by("SqlitePersistence") }
    db = File.join(@dir, "ledger.db")
    Hecks.world("Ledger") { persisted_by("SqlitePersistence") { database(db) } }
  end

  def run(runtime, *argv)
    Hecks::Adapters::Driving::CliRunner.call(runtime: runtime, argv: argv, program: "hecks run")
  end

  it "reads the rows written under the former name after the rename" do
    File.write(fixture, source("Entry"))
    first = run(boot, "Entry.post!", "run=k1", "label=rent")
    File.write(fixture, source("Journal", "Entry"))
    expect(run(boot, "Journal.post!", "run=k1", "label=rent")).to eq(first)
  end

  it "resolves the former spelling to the renamed command and notes it once on standard error" do
    File.write(fixture, source("Entry"))
    run(boot, "Entry.post!", "run=k2", "label=rent")
    File.write(fixture, source("Journal", "Entry"))
    expect { run(boot, "Entry.post!", "run=k2", "label=rent") }
      .to output(/Entry\.post is the former name of .*Journal/).to_stderr
  end

  it "refuses a name that no aggregate carries, as a usage error" do
    File.write(fixture, source("Journal", "Entry"))
    expect(run(boot, "Nothing.post", "run=k3", "label=rent").last).to eq(Hecks::Adapters::Driving::ExitStatus::USAGE)
  end
end
