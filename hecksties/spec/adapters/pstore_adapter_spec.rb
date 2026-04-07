require "spec_helper"
require "tmpdir"
require "fileutils"
require "hecks/adapters/pstore_adapter"

PStoreTestItem = Struct.new(:id, :name, :color, keyword_init: true)

RSpec.describe Hecks::Adapters::PStoreAdapter do
  let(:tmpdir) { Dir.mktmpdir("hecks-pstore-") }
  let(:pstore_path) { File.join(tmpdir, "test.pstore") }
  let(:pstore) { Hecks::Adapters::PStoreAdapter.new(pstore_path) }

  after { FileUtils.rm_rf(tmpdir) }

  it "persists and retrieves objects" do
    pstore.save(PStoreTestItem.new(id: "abc", name: "Test"))
    expect(File.exist?(pstore_path)).to be true
    expect(pstore.count).to eq(1)
    expect(pstore.find("abc").name).to eq("Test")
  end

  it "supports all, delete, clear" do
    pstore.save(PStoreTestItem.new(id: "1", name: "A"))
    pstore.save(PStoreTestItem.new(id: "2", name: "B"))
    expect(pstore.all.size).to eq(2)

    pstore.delete("1")
    expect(pstore.count).to eq(1)

    pstore.clear
    expect(pstore.count).to eq(0)
  end

  it "supports query with conditions" do
    pstore.save(PStoreTestItem.new(id: "1", name: "Apple", color: "red"))
    pstore.save(PStoreTestItem.new(id: "2", name: "Banana", color: "yellow"))
    pstore.save(PStoreTestItem.new(id: "3", name: "Cherry", color: "red"))

    results = pstore.query(conditions: { color: "red" })
    expect(results.size).to eq(2)
    expect(results.map(&:name)).to contain_exactly("Apple", "Cherry")
  end

  it "supports query with ordering and pagination" do
    pstore.save(PStoreTestItem.new(id: "1", name: "C"))
    pstore.save(PStoreTestItem.new(id: "2", name: "A"))
    pstore.save(PStoreTestItem.new(id: "3", name: "B"))

    results = pstore.query(order_key: :name, limit: 2)
    expect(results.map(&:name)).to eq(["A", "B"])

    results = pstore.query(order_key: :name, order_direction: :desc, limit: 1)
    expect(results.map(&:name)).to eq(["C"])
  end
end
