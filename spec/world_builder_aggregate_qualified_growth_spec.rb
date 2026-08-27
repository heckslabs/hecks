require "spec_helper"

# Real coverage for issue #143: a `.world` file's own aggregate-qualified
# bind mirror (`Pizzas::Order.charged_by("Stripe") do ... end` — the SAME
# visual shape `.hecksagon` files already write, since `.world`/`.hecksagon`
# are meant to mirror each other line for line) raised
# `NameError: uninitialized constant Pizzas` — `WorldBuilder`, unlike
# `HecksagonBuilder`/`BluebookBuilder`, never wrapped its own
# `instance_eval` in `ConstShim`, so a bareword aggregate name had no real
# constant to resolve to.
RSpec.describe "WorldBuilder aggregate-qualified bind mirror" do
  def build_world(&block) = Hecks::Bluebook::DSL::WorldBuilder.build("AggregateQualifiedGrowth", &block)

  it "resolves an aggregate-qualified verb without raising" do
    expect do
      build_world do
        realm "Examples"
        latest "v1"
        Widgets::Thing.persisted_by("Heki") do
          dir "data"
        end
      end
    end.not_to raise_error
  end

  it "writes into the exact same @settings path a bare top-level call does" do
    qualified = build_world do
      realm "Examples"
      latest "v1"
      Widgets::Thing.persisted_by("Heki") do
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
      Widgets::Thing.projected_by("SqliteProjection") do
        database "data/thing.sqlite3"
      end
    end

    expect(world.settings["projected_by"]).to eq(adapter: "SqliteProjection", database: "data/thing.sqlite3")
    expect(world.settings["projected_by:sqliteprojection"]).to eq(world.settings["projected_by"])
  end
end
