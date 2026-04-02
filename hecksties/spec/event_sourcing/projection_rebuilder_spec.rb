require "hecks"

RSpec.describe "HEC-64: ProjectionRebuilder" do
  let(:event_store) { Hecks::EventSourcing::EventStore.new }

  let(:projections) do
    {
      "CreatedPizza" => ->(data, state) {
        count = (state[:count] || 0) + 1
        state.merge(count: count, last_name: data["name"])
      }
    }
  end

  it "rebuilds state from all events" do
    event_store.append("Pizza-1", event_type: "CreatedPizza", data: { "name" => "M" })
    event_store.append("Pizza-2", event_type: "CreatedPizza", data: { "name" => "P" })

    rebuilder = Hecks::EventSourcing::ProjectionRebuilder.new(event_store)
    state = rebuilder.rebuild(projections)

    expect(state[:count]).to eq(2)
    expect(state[:last_name]).to eq("P")
  end

  it "rebuilds from a single stream" do
    event_store.append("Pizza-1", event_type: "CreatedPizza", data: { "name" => "M" })
    event_store.append("Pizza-2", event_type: "CreatedPizza", data: { "name" => "P" })

    rebuilder = Hecks::EventSourcing::ProjectionRebuilder.new(event_store)
    state = rebuilder.rebuild_stream("Pizza-1", projections)

    expect(state[:count]).to eq(1)
    expect(state[:last_name]).to eq("M")
  end

  it "applies upcasting during rebuild" do
    registry = Hecks::EventSourcing::UpcasterRegistry.new
    registry.register("CreatedPizza", from: 1, to: 2) do |data|
      data.merge("size" => "large")
    end
    engine = Hecks::EventSourcing::UpcasterEngine.new(registry)

    event_store.append("Pizza-1", event_type: "CreatedPizza", data: { "name" => "M" }, schema_version: 1)

    size_proj = { "CreatedPizza" => ->(data, state) { state.merge(size: data["size"]) } }
    rebuilder = Hecks::EventSourcing::ProjectionRebuilder.new(event_store, upcaster_engine: engine)
    state = rebuilder.rebuild(size_proj)

    expect(state[:size]).to eq("large")
  end

  it "skips events with no matching projection" do
    event_store.append("X-1", event_type: "UnknownEvent", data: {})
    rebuilder = Hecks::EventSourcing::ProjectionRebuilder.new(event_store)
    state = rebuilder.rebuild(projections)
    expect(state).to eq({})
  end
end
