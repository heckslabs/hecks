require "hecks"

RSpec.describe "EventStore" do
  let(:store) { Hecks::EventSourcing::EventStore.new }

  it "appends events to a stream with auto-incrementing versions" do
    e1 = store.append("Pizza-1", event_type: "CreatedPizza", data: { "name" => "M" })
    e2 = store.append("Pizza-1", event_type: "RenamedPizza", data: { "name" => "N" })

    expect(e1.version).to eq(1)
    expect(e2.version).to eq(2)
    expect(e1.global_position).to eq(1)
    expect(e2.global_position).to eq(2)
  end

  it "reads a full stream" do
    store.append("Pizza-1", event_type: "CreatedPizza", data: { "name" => "M" })
    store.append("Pizza-1", event_type: "RenamedPizza", data: { "name" => "N" })

    events = store.read_stream("Pizza-1")
    expect(events.size).to eq(2)
    expect(events.map(&:event_type)).to eq(["CreatedPizza", "RenamedPizza"])
  end

  it "reads from a specific version" do
    store.append("Pizza-1", event_type: "A", data: {})
    store.append("Pizza-1", event_type: "B", data: {})
    store.append("Pizza-1", event_type: "C", data: {})

    events = store.read_stream("Pizza-1", from_version: 2)
    expect(events.map(&:event_type)).to eq(["B", "C"])
  end

  it "enforces optimistic concurrency on append" do
    store.append("Pizza-1", event_type: "A", data: {})

    expect {
      store.append("Pizza-1", event_type: "B", data: {}, expected_version: 0)
    }.to raise_error(Hecks::ConcurrencyError)

    # Correct expected version succeeds
    store.append("Pizza-1", event_type: "B", data: {}, expected_version: 1)
    expect(store.stream_version("Pizza-1")).to eq(2)
  end

  it "reads events up to a version" do
    store.append("X-1", event_type: "A", data: {})
    store.append("X-1", event_type: "B", data: {})
    store.append("X-1", event_type: "C", data: {})

    events = store.read_stream_to_version("X-1", 2)
    expect(events.map(&:event_type)).to eq(["A", "B"])
  end

  it "reads events up to a timestamp" do
    t1 = Time.new(2026, 1, 1, 12, 0, 0)
    t2 = Time.new(2026, 1, 1, 13, 0, 0)
    t3 = Time.new(2026, 1, 1, 14, 0, 0)

    store.append("X-1", event_type: "A", data: {}, occurred_at: t1)
    store.append("X-1", event_type: "B", data: {}, occurred_at: t2)
    store.append("X-1", event_type: "C", data: {}, occurred_at: t3)

    events = store.read_stream_until("X-1", Time.new(2026, 1, 1, 13, 30, 0))
    expect(events.map(&:event_type)).to eq(["A", "B"])
  end

  it "returns all events across streams in global order" do
    store.append("A-1", event_type: "X", data: {})
    store.append("B-1", event_type: "Y", data: {})
    store.append("A-1", event_type: "Z", data: {})

    types = store.all_events.map(&:event_type)
    expect(types).to eq(["X", "Y", "Z"])
  end

  it "clears all events" do
    store.append("A-1", event_type: "X", data: {})
    store.clear
    expect(store.all_events).to be_empty
    expect(store.stream_version("A-1")).to eq(0)
  end
end
