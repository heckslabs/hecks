# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "pg"
require "hecks/hecks/adapters/journal_store"
require_relative "../../../support/postgres_probe"
require_relative "../../../support/scratch_postgres"
require_relative "../../../support/event_trace_shop"

# The event trace on a scratch PostgresEra database: the same delivered, refused and unheard
# outcomes as on SQLite, read over a session that cannot write.
RSpec.describe "the event trace on PostgresEra", :io do
  EVENT_TRACE_SPEC_DB = "hecks_event_trace_spec"

  scratch_postgres EVENT_TRACE_SPEC_DB

  # A `before`, not an `around`: the scratch database is scrubbed in a `before` and an `around`
  # would write the events first.
  before do
    @dir = Dir.mktmpdir("event-trace-pg-")
    EventTraceShop.write(@dir, adapter: "PostgresEra", world: EventTraceShop.postgres_world(EVENT_TRACE_SPEC_DB))
    EventTraceShop.run(@dir)
  end

  after { FileUtils.remove_entry(@dir) }

  def counts
    db = PG.connect(dbname: EVENT_TRACE_SPEC_DB)
    %w[events hecks_outbox].map { |table| db.exec("SELECT count(*) FROM #{table}").getvalue(0, 0).to_i }
  ensure
    db&.close
  end

  it "reports delivered, refused with its reason, and no subscriber", :aggregate_failures do
    report = EventTraceShop.trace(@dir)
    expect(EventTraceShop.outcomes(report)).to include(["OrderPlaced", "policy:Trace::RecordOrder", "delivered"],
                                                       ["OrderPlaced", "policy:Trace::RehearseOrder", "refused"])
    expect(report[:no_subscriber].map { |event| event[:name] }).to include("OrderTouched")
  end

  it "names the key the refused trigger could not read" do
    refused = EventTraceShop.trace(@dir)[:events].flat_map { |row| row[:subscribers] }.find { |s| s[:outcome] == "refused" }
    expect(refused[:reason]).to include("checkout")
  end

  it "writes nothing to the database" do
    before = counts
    EventTraceShop.trace(@dir)
    expect(counts).to eq(before)
  end

  it "reads over a session that refuses a write" do
    reader = Hecks::Adapters::JournalStore::Readings::EventTrace::PostgresReader.open("Trace", database: EVENT_TRACE_SPEC_DB)
    expect { reader.send(:run, "DELETE FROM events", []) }.to raise_error(PG::ReadOnlySqlTransaction)
  ensure
    reader&.close
  end
end
