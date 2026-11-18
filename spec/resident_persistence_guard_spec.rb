require "spec_helper"
require "tmpdir"
require "hecks/adapters/driving/resident/server"

# A resident that resolved an aggregate to Memory which the checkout's local hecksagon binds to
# SQLite answers success and writes nothing the ledger holds; it refuses by name instead.
RSpec.describe Hecks::Adapters::Driving::Resident::PersistenceGuard do
  let(:guard) { described_class }
  let(:bind) { %(Hecks.hecksagon "Tickets" do\n  Tickets::Work.persisted_by("SqlitePersistence")\nend\n) }

  def domain_with(text)
    Dir.mktmpdir("hrpg") do |dir|
      File.write(File.join(dir, "hecks.local.hecksagon"), text) if text
      yield dir
    end
  end

  def rows(store) = [["store Tickets", "Memory", "default"], ["store Tickets::Work", store, "aggregate bind"]]

  describe "what the local hecksagons declare" do
    it "names the aggregates bound to SQLite" do
      domain_with(bind) { |dir| expect(guard.declared(dir, {})).to eq(["Tickets::Work"]) }
    end

    it "names none when the checkout keeps no local hecksagon" do
      domain_with(nil) { |dir| expect(guard.declared(dir, {})).to eq([]) }
    end
  end

  describe "comparing them with what the registry resolved" do
    it "finds an aggregate declared on SQLite that loaded on Memory" do
      expect(guard.gap(["Tickets::Work"], rows("Memory"))).to eq("Tickets::Work")
    end

    it "finds none when the aggregate loaded on SQLite" do
      expect(guard.gap(["Tickets::Work"], rows("SqliteAt /x.db"))).to be_nil
    end

    it "finds none for an aggregate on Memory that nothing declares on SQLite" do
      expect(guard.gap([], rows("Memory"))).to be_nil
    end
  end

  describe "the lines meant to run on Memory" do
    it "exempts the spec switch and the memory and test environments", :aggregate_failures do
      expect(guard.exempt?("HECKS_WRITES_LOCAL" => "1")).to be(true)
      expect(guard.exempt?("HECKS_ENVIRONMENT" => "memory")).to be(true)
      expect(guard.exempt?("HECKS_ENVIRONMENT" => "test")).to be(true)
    end

    it "does not exempt a plain line" do
      expect(guard.exempt?({})).to be(false)
    end
  end

  describe "a resident that holds such a gap" do
    let(:server) { Hecks::Adapters::Driving::Resident::Server.new("/checkout", "/checkout/exe/hecks") }

    before do
      server.instance_variable_set(:@persistence_gap, "Tickets::Work")
      allow(server).to receive(:retire)
    end

    it "refuses a plain line by the aggregate's name and retires", :aggregate_failures do
      expect(server.send(:unpersisted, {})).to eq("persistence:Tickets::Work")
      expect(server).to have_received(:retire).once
    end

    it "serves a line that asks for Memory, and does not retire", :aggregate_failures do
      expect(server.send(:unpersisted, "HECKS_ENVIRONMENT" => "memory")).to be_nil
      expect(server).not_to have_received(:retire)
    end

    it "is not counted as an environment refusal, so it never replaces itself in a loop" do
      expect(Hecks::Adapters::Driving::Resident::Atypical.env?("persistence:Tickets::Work")).to be(false)
    end
  end

  describe "the launcher that meets the refusal" do
    let(:client) { Hecks::Adapters::Driving::Resident::Client }

    before do
      allow(client).to receive_messages(ask: [nil, "persistence:Tickets::Work"], spawn_resident: "started")
      allow(Hecks::Adapters::Driving::Resident::Stuck).to receive(:after)
    end

    it "boots the line on its own, so it runs on the ledger, and starts a new resident", :aggregate_failures do
      outcome = client.attempt("/checkout", "/checkout/exe/hecks")
      expect(outcome).to eq(Hecks::Adapters::Driving::Resident::Outcome.refused("persistence:Tickets::Work"))
      expect(client).to have_received(:spawn_resident).once
    end
  end
end
