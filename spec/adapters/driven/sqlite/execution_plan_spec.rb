require "spec_helper"
require "tmpdir"

RSpec.describe "SQLite execution-plan capabilities" do
  def item_aggregate
    Hecks::Bluebook::DSL::BluebookBuilder.build("SqlitePlanning") do
      vision "SQLite implements the same atomic-put contract as Memory"

      aggregate "Item" do
        identified_by do
          attribute :sku, String
        end

        value_object("Label") { attribute :value, String }
        attribute :label, Label
      end
    end.aggregate("Item")
  end

  it "atomically appends and projects while reporting insert versus replacement" do
    Dir.mktmpdir("hecks-sqlite-plan-") do |root|
      aggregate = item_aggregate
      adapter = Hecks::Adapters::Sqlite.new(
        aggregate: aggregate,
        settings:  { database: "items.db" },
        root:      root
      )
      repository = Hecks::Ports::Persistence::AppendOnly.new(adapter)

      first = Hecks::Runtime::Instance.new(
        aggregate: aggregate,
        id:        "sku-1",
        state:     { identity: { sku: "sku-1" }, label: { value: "First" } }
      )
      second = Hecks::Runtime::Instance.new(
        aggregate: aggregate,
        id:        "sku-1",
        state:     { identity: { sku: "sku-1" }, label: { value: "Second" } }
      )

      expect(repository.capabilities).to eq([:atomic_put])
      expect(repository.atomic_put(first).status).to eq(:inserted)
      expect(repository.atomic_put(second).status).to eq(:replaced)
      expect(repository.entries.size).to eq(2)
      expect(repository.find("sku-1").state[:label].to_h).to eq(value: "Second")
    end
  end
end
