require "tmpdir"
require "fileutils"
require "hecks/hecks/adapters/journal_store/event_compaction"

# Dropping the events of a Sqlite store's shared log past a window, through the compaction the
# `SchemaRevision.CompactEvents` command runs, against an on-disk copy of a small fixture domain.
RSpec.describe Hecks::Adapters::JournalStore::EventCompaction do
  let(:fixture) { File.join(InMemoryDomain::ROOT, "spec/fixtures/heki_compact_fixture/bluebook") }
  let(:now) { Time.utc(2026, 1, 31) }

  around do |example|
    @dir = Dir.mktmpdir("hecks-event-compaction-spec-")
    example.run
  ensure
    FileUtils.remove_entry(@dir) if @dir
  end

  def sqlite_domain
    target = File.join(@dir, "bluebook")
    FileUtils.cp_r(fixture, target)
    File.write(File.join(target, "heki_compact_fixture.hecksagon"),
               "Hecks.hecksagon \"HekiCompactFixture\" do\n  persisted_by \"SqlitePersistence\"\nend\n")
    File.write(File.join(target, "heki_compact_fixture.world"),
               "Hecks.world \"HekiCompactFixture\" do\n  default_adapter \"SqlitePersistence\"\nend\n")
    target
  end

  def seed(dir, days_ago)
    registry = Hecks.boot(dir, install_driving: false).registry
    aggregate = registry.bluebook("HekiCompactFixture").aggregate("Gadget")
    days_ago.each_with_index do |ago, n|
      registry.repository("HekiCompactFixture", aggregate).record_event(
        Hecks::Runtime::Event.new(name: "GadgetMade", aggregate: "HekiCompactFixture::Gadget", id: "g#{n}",
                                  payload: {}, occurred_at: (now - (ago * 86_400)).iso8601)
      )
    end
  end

  def log(dir, days = 10) = described_class.new(dir, window_days: days, now: now)

  it "refuses a nonexistent domain path, naming it" do
    expect { log(File.join(@dir, "nowhere")) }.to raise_error(Hecks::Runtime::NotFound, /nowhere/)
  end

  it "counts the events older than the window", :aggregate_failures do
    dir = sqlite_domain
    seed(dir, [40, 20, 5, 1])

    expect(log(dir).candidates).to eq(2)
    expect(log(dir).bound).to eq(0)
  end

  it "drops the events older than the window and keeps the rest", :aggregate_failures do
    dir = sqlite_domain
    seed(dir, [40, 20, 5, 1])

    expect(log(dir).apply!.first).to match(/dropped 2 events/)
    expect(log(dir).candidates).to eq(0)
  end
end
