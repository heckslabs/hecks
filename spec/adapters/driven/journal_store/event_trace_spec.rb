# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "hecks/hecks/adapters/journal_store"
require_relative "../../../support/event_trace_shop"

# The event trace on a disposable domain: two policies listen to one event (one delivers, one is
# refused for a key the event lacks), another event has no listener, and a ring of reactions meets
# the depth limit. The trace joins each event to its listeners and the outcome the store holds.
RSpec.describe Hecks::Adapters::JournalStore::Readings::EventTrace do
  def trace(dir, **args) = EventTraceShop.trace(dir, **args)

  def outcomes(report) = EventTraceShop.outcomes(report)

  def lay_out(dir, db) = EventTraceShop.write(dir, adapter: "SqlitePersistence", world: EventTraceShop.sqlite_world(db))

  describe "on a scratch SQLite store" do
    around do |example|
      Dir.mktmpdir("event-trace-") do |dir|
        @dir = dir
        @db = File.join(dir, "trace.db")
        lay_out(dir, @db)
        EventTraceShop.run(dir)
        example.run
      end
    end

    it "reports the policy that delivered" do
      expect(outcomes(trace(@dir))).to include(["OrderPlaced", "policy:Trace::RecordOrder", "delivered"])
    end

    it "reports the refused policy with the reason its trigger gave", :aggregate_failures do
      refused = trace(@dir)[:events].flat_map { |row| row[:subscribers] }.find { |s| s[:outcome] == "refused" }
      expect(refused[:consumer]).to eq("policy:Trace::RehearseOrder")
      expect(refused[:reason]).to include("checkout")
    end

    it "lists the event nobody listens to" do
      expect(trace(@dir)[:no_subscriber].map { |event| event[:name] }).to include("OrderTouched")
    end

    it "lists the policy whose event has never occurred" do
      expect(trace(@dir)[:never_occurred].map { |policy| policy[:consumer] }).to include("policy:Trace::ShelveOrder")
    end

    it "selects by event name" do
      expect(trace(@dir, event: "OrderTouched")[:events].map { |row| row[:event][:name] }).to eq(["OrderTouched"])
    end

    it "keeps only the newest N events" do
      expect(trace(@dir, last: 1)[:events].size).to eq(1)
    end

    it "closes with a one-line summary" do
      expect(trace(@dir)[:summary]).to match(/\A3 events in 1 store\(s\); outcomes: 1 delivered, 1 refused;/)
    end

    it "writes nothing: the file's bytes and modification time are unchanged" do
      before = [File.binread(@db), File.mtime(@db), Dir.children(@dir).sort]
      trace(@dir)
      expect([File.binread(@db), File.mtime(@db), Dir.children(@dir).sort]).to eq(before)
    end
  end

  describe "when a reaction cascades past the depth limit" do
    around do |example|
      Dir.mktmpdir("event-trace-depth-") do |dir|
        @dir = dir
        lay_out(dir, File.join(dir, "trace.db"))
        runtime = EventTraceShop.run(dir)
        runtime.dispatch("Trace::Order.Ping", to: "o-1")
        example.run
      end
    end

    it "records the depth refusal in the outbox with its reason" do
      refusals = trace(@dir)[:events].flat_map { |row| row[:subscribers] }.select { |s| s[:outcome] == "refused" }
      expect(refusals.map { |s| s[:reason] }).to include(/reaction depth \d+ reached/)
    end
  end

  describe "on Memory" do
    around do |example|
      Dir.mktmpdir("event-trace-memory-") do |dir|
        @dir = dir
        EventTraceShop.write(dir)
        example.run
      end
    end

    it "says Memory keeps no log", :aggregate_failures do
      report = trace(@dir)
      expect(report[:stores].first[:state]).to include("Memory keeps no log")
      expect(report[:events]).to eq([])
    end
  end
end
