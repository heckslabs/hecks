require "spec_helper"

# A `.world` aggregate-qualified bind (`Pizzas::Order.charged_by("Stripe") do ... end`) must
# resolve the bareword aggregate name; WorldBuilder wraps instance_eval in ConstShim like siblings.
# The name must be one no spec boots as a real domain: a booted domain leaves a top-level
# constant behind, and the bareword would then resolve to it instead of reaching ConstShim.
RSpec.describe "WorldBuilder aggregate-qualified bind mirror" do
  def build_world(&block) = Hecks::Bluebook::DSL::WorldBuilder.build("AggregateQualifiedGrowth", &block)

  it "writes into the exact same @settings path a bare top-level call does" do
    qualified = build_world do
      realm "Examples"
      latest "v1"
      Gizmos::Thing.persisted_by("Heki") do
        dir "data"
      end
    end

    bare = build_world do
      realm "Examples"
      latest "v1"
      persisted_by("Heki") do
        dir "data"
      end
    end

    expect(qualified.settings).to eq(bare.settings)
  end

  it "the bare top-level and aggregate-qualified spellings produce identical settings" do
    world = build_world do
      realm "Examples"
      latest "v1"
      Gizmos::Thing.projected_by("SqliteProjection") do
        database "data/thing.sqlite3"
      end
    end

    expect(world.settings["projected_by"]).to eq(adapter: "SqliteProjection", database: "data/thing.sqlite3")
    expect(world.settings["projected_by:sqliteprojection"]).to eq(world.settings["projected_by"])
  end
end
