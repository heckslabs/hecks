require "hecks"

RSpec.describe "HEC-63: CQRS ReadModelStore" do
  let(:store) { Hecks::EventSourcing::ReadModelStore.new }

  it "stores and retrieves read models by key" do
    store.put("orders:summary", { total: 5 })
    expect(store.get("orders:summary")).to eq({ total: 5 })
  end

  it "returns nil for missing keys" do
    expect(store.get("missing")).to be_nil
  end

  it "deletes a read model" do
    store.put("x", { a: 1 })
    store.delete("x")
    expect(store.get("x")).to be_nil
  end

  it "clears all read models" do
    store.put("a", 1)
    store.put("b", 2)
    store.clear
    expect(store.keys).to be_empty
  end

  it "lists all keys" do
    store.put("x", 1)
    store.put("y", 2)
    expect(store.keys).to contain_exactly("x", "y")
  end

  it "returns a dup from get to prevent mutation" do
    store.put("x", { a: 1 })
    result = store.get("x")
    result[:b] = 2
    expect(store.get("x")).to eq({ a: 1 })
  end
end
