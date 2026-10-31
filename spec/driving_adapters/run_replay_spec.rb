require "spec_helper"
require "tmpdir"

# A creating command that names a run key the store already holds answers the record written
# first, when the arguments match, and refuses when they differ. Memory holds no run across
# processes, so only a persisting store answers the repeat.
RSpec.describe Hecks::Adapters::Driving::CliRunner::RunReplay do
  around do |example|
    @dir = Dir.mktmpdir("hecks-run-replay-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  let(:fixture) { File.join(@dir, "ledger.bluebook") }
  let(:sqlite_adapter) { File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/sqlite.adapter") }
  let(:ledger_source) do
    <<~RUBY
      Hecks.bluebook "Ledger" do
        aggregate "Entry" do
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
        end
      end
    RUBY
  end

  def boot(persist:)
    registry = Hecks::Runtime::Registry.new(root: @dir)
    Hecks.with_registry(registry) { declare(persist) }
    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def declare(persist)
    Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
    Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
    Kernel.load(sqlite_adapter)
    Kernel.load(fixture)
    Hecks.hecksagon("Ledger") { persisted_by(persist ? "SqlitePersistence" : "Memory") }
    db = File.join(@dir, "ledger.db")
    Hecks.world("Ledger") { persisted_by("SqlitePersistence") { database(db) } } if persist
  end

  def run(runtime, *argv)
    Hecks::Adapters::Driving::CliRunner.call(runtime: runtime, argv: argv, program: "hecks run")
  end

  before { File.write(fixture, ledger_source) }

  it "answers the first record for a repeat with the same key and arguments" do
    runtime = boot(persist: true)
    first = run(runtime, "Entry.post", "run=k1", "label=rent")
    expect(run(runtime, "Entry.post", "run=k1", "label=rent")).to eq(first)
  end

  it "refuses a repeat of a key with different arguments" do
    runtime = boot(persist: true)
    run(runtime, "Entry.post", "run=k1", "label=rent")
    expect(run(runtime, "Entry.post", "run=k1", "label=food").last).to eq(Hecks::Adapters::Driving::ExitStatus::REFUSED)
  end

  it "names Memory and the persistent store when a Memory repeat is refused" do
    runtime = boot(persist: false)
    run(runtime, "Entry.post", "run=k2", "label=rent")
    expect(run(runtime, "Entry.post", "run=k2", "label=rent").first).to include("Memory", "SQLite")
  end
end
