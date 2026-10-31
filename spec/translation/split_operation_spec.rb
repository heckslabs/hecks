require "spec_helper"

# ADR 0166: a translation's `split` writes rows into other aggregates from one aggregate's rows.
# The aggregate builder refuses a split missing its target, its key or its fields. Whether a
# target is fed, and whether its key is its identity, is checked when the edge is built.
RSpec.describe "the translation split operation" do
  def edge(&block)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      Hecks.data_translation("Shop", from: "aaa111", to: "bbb222", &block)
    end
  end

  it "admits a split that copies named fields into a target keyed by a shared field" do
    expect { edge { aggregate("Collection") { split into: "CollectionLayout", keyed_by: :agg, fields: %i[columns] } } }
      .not_to raise_error
  end

  it "refuses a split with no fields to copy" do
    expect { edge { aggregate("Collection") { split into: "CollectionLayout", keyed_by: :agg, fields: [] } } }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /fields/)
  end

  it "refuses a split with no target" do
    expect { edge { aggregate("Collection") { split keyed_by: :agg, fields: %i[columns] } } }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /into/)
  end
end
