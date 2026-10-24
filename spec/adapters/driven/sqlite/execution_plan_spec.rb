require "spec_helper"
require "tmpdir"
require_relative "../../../support/persistence_adapter_examples"

RSpec.describe "SQLite execution-plan capabilities" do
  include_context "with the atomic_put Item aggregate"

  scratch_directory :root, "hecks-sqlite-plan-"

  let(:aggregate) { item_aggregate("SqlitePlanning", "SQLite implements the same atomic-put contract as Memory") }
  let(:store) do
    adapter = Hecks::Adapters::Sqlite.new(aggregate: aggregate, settings: { database: "items.db" }, root: @root)
    Hecks::Ports::Persistence::AppendOnly.new(adapter)
  end

  it "reports the one capability it has" do
    expect(store.capabilities).to eq(%i[atomic_put rollback])
  end

  it_behaves_like "an atomic_put adapter"
end
