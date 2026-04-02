require "hecks"

RSpec.describe "HEC-69: Aggregate Snapshots" do
  describe "SnapshotStore" do
    let(:store) { Hecks::EventSourcing::SnapshotStore.new }

    it "saves and loads snapshots" do
      store.save("Pizza-1", version: 5, state: { name: "Margherita" })
      snap = store.load("Pizza-1")

      expect(snap.version).to eq(5)
      expect(snap.state).to eq({ name: "Margherita" })
      expect(snap.stream_id).to eq("Pizza-1")
    end

    it "returns nil for missing snapshots" do
      expect(store.load("missing")).to be_nil
    end

    it "overwrites existing snapshots" do
      store.save("Pizza-1", version: 5, state: { name: "Old" })
      store.save("Pizza-1", version: 10, state: { name: "New" })

      snap = store.load("Pizza-1")
      expect(snap.version).to eq(10)
      expect(snap.state[:name]).to eq("New")
    end

    it "deletes snapshots" do
      store.save("Pizza-1", version: 5, state: {})
      store.delete("Pizza-1")
      expect(store.load("Pizza-1")).to be_nil
    end

    it "clears all snapshots" do
      store.save("A", version: 1, state: {})
      store.save("B", version: 1, state: {})
      store.clear
      expect(store.load("A")).to be_nil
    end
  end

  describe "Reconstitution" do
    let(:event_store) { Hecks::EventSourcing::EventStore.new }
    let(:snapshot_store) { Hecks::EventSourcing::SnapshotStore.new }

    let(:appliers) do
      {
        "Created" => ->(state, data) { state.merge(name: data["name"], count: 0) },
        "Incremented" => ->(state, _data) { state.merge(count: (state[:count] || 0) + 1) }
      }
    end

    it "reconstitutes from events only" do
      event_store.append("X-1", event_type: "Created", data: { "name" => "Test" })
      event_store.append("X-1", event_type: "Incremented", data: {})
      event_store.append("X-1", event_type: "Incremented", data: {})

      r = Hecks::EventSourcing::Reconstitution.new(event_store)
      state = r.reconstitute("X-1", appliers)

      expect(state[:name]).to eq("Test")
      expect(state[:count]).to eq(2)
    end

    it "reconstitutes from snapshot + subsequent events" do
      5.times { event_store.append("X-1", event_type: "Incremented", data: {}) }
      snapshot_store.save("X-1", version: 3, state: { name: "Test", count: 3 })
      # Events 4 and 5 should still be replayed
      r = Hecks::EventSourcing::Reconstitution.new(event_store, snapshot_store: snapshot_store)
      state = r.reconstitute("X-1", appliers)

      expect(state[:count]).to eq(5)
    end

    it "auto-snapshots at configurable intervals" do
      r = Hecks::EventSourcing::Reconstitution.new(
        event_store, snapshot_store: snapshot_store, snapshot_interval: 3
      )

      3.times { event_store.append("X-1", event_type: "Incremented", data: {}) }
      r.reconstitute("X-1", appliers)

      snap = snapshot_store.load("X-1")
      expect(snap).not_to be_nil
      expect(snap.version).to eq(3)
    end
  end
end
