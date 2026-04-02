require "hecks"

RSpec.describe "HEC-98: Time Travel" do
  let(:event_store) { Hecks::EventSourcing::EventStore.new }
  let(:tt) { Hecks::EventSourcing::TimeTravel.new(event_store) }

  let(:appliers) do
    {
      "Created" => ->(state, data) { state.merge(name: data["name"]) },
      "Renamed" => ->(state, data) { state.merge(name: data["name"]) },
      "Tagged"  => ->(state, data) { state.merge(tag: data["tag"]) }
    }
  end

  before do
    @t1 = Time.new(2026, 1, 1, 10, 0, 0)
    @t2 = Time.new(2026, 1, 1, 11, 0, 0)
    @t3 = Time.new(2026, 1, 1, 12, 0, 0)

    event_store.append("Pizza-1", event_type: "Created", data: { "name" => "Original" }, occurred_at: @t1)
    event_store.append("Pizza-1", event_type: "Renamed", data: { "name" => "V2" }, occurred_at: @t2)
    event_store.append("Pizza-1", event_type: "Tagged", data: { "tag" => "special" }, occurred_at: @t3)
  end

  describe "#as_of" do
    it "returns state at a specific timestamp" do
      state = tt.as_of("Pizza-1", @t1 + 1, appliers)
      expect(state[:name]).to eq("Original")
      expect(state[:tag]).to be_nil
    end

    it "includes events up to the timestamp" do
      state = tt.as_of("Pizza-1", @t2, appliers)
      expect(state[:name]).to eq("V2")
    end

    it "returns full state when timestamp is after all events" do
      state = tt.as_of("Pizza-1", @t3 + 3600, appliers)
      expect(state[:name]).to eq("V2")
      expect(state[:tag]).to eq("special")
    end
  end

  describe "#at_version" do
    it "returns state at a specific version" do
      state = tt.at_version("Pizza-1", 1, appliers)
      expect(state[:name]).to eq("Original")
    end

    it "returns state through version 2" do
      state = tt.at_version("Pizza-1", 2, appliers)
      expect(state[:name]).to eq("V2")
      expect(state[:tag]).to be_nil
    end

    it "returns full state at latest version" do
      state = tt.at_version("Pizza-1", 3, appliers)
      expect(state[:tag]).to eq("special")
    end
  end
end
