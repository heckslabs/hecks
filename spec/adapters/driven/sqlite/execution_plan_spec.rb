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

  around do |example|
    Dir.mktmpdir("hecks-sqlite-plan-") do |root|
      @root = root
      example.run
    end
  end

  let(:aggregate) { item_aggregate }
  let(:repository) do
    adapter = Hecks::Adapters::Sqlite.new(aggregate: aggregate, settings: { database: "items.db" }, root: @root)
    Hecks::Ports::Persistence::AppendOnly.new(adapter)
  end

  def item_labelled(value)
    Hecks::Runtime::Instance.new(
      aggregate: aggregate,
      id:        "sku-1",
      state:     { identity: { sku: "sku-1" }, label: { value: value } }
    )
  end

  it "reports the one capability it has" do
    expect(repository.capabilities).to eq([:atomic_put])
  end

  it "reports an insert for the first put of an identity" do
    expect(repository.atomic_put(item_labelled("First")).status).to eq(:inserted)
  end

  it "reports a replacement for the second put of an identity" do
    repository.atomic_put(item_labelled("First"))

    expect(repository.atomic_put(item_labelled("Second")).status).to eq(:replaced)
  end

  it "appends every put, and finds the latest" do
    repository.atomic_put(item_labelled("First"))
    repository.atomic_put(item_labelled("Second"))

    expect([repository.entries.size, repository.find("sku-1").state[:label].to_h]).to eq([2, { value: "Second" }])
  end
end
