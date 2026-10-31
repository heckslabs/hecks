require "spec_helper"

# ADR 0166: a translation's `split` writes rows into other aggregates from one aggregate's rows.
# The builder refuses a split whose key is not the target's identity, and a target that no split
# or backfill feeds. Both are build-time refusals, not mint-time surprises.
RSpec.describe "the translation split operation" do
  def edge(&block)
    Hecks.data_translation("Shop", from: "aaa111", to: "bbb222", &block)
  end

  it "builds a split that feeds each target from the source's own key" do
    expect { edge { aggregate("Collection") { split into: "CollectionLayout", keyed_by: :agg, fields: %i[columns] } } }
      .not_to raise_error
  end

  it "refuses a split keyed by a field the target does not identify by" do
    expect { edge { aggregate("Collection") { split into: "CollectionLayout", keyed_by: :label, fields: %i[columns] } } }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /keyed_by/)
  end

  it "refuses a target aggregate that no split or backfill feeds" do
    expect { edge { aggregate("Collection") { split into: "CollectionLayout", keyed_by: :agg, fields: %i[columns] } } }
      .not_to raise_error
    expect { edge { aggregate("Collection") { drop :columns } } }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /CollectionLayout/)
  end
end
