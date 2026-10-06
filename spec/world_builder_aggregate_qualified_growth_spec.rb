require "spec_helper"

# A `.world` aggregate-qualified bind (`Pizzas::Order.charged_by("Stripe") do ... end`) must
# resolve the bareword aggregate name; WorldBuilder wraps instance_eval in ConstShim like siblings.
RSpec.describe "WorldBuilder aggregate-qualified bind mirror" do
  def build_world(&block) = Hecks::Bluebook::DSL::WorldBuilder.build("AggregateQualifiedGrowth", &block)

  # A world with the realm and version every example here shares, then `body`'s own declarations.
  def build_examples_world(&body)
    build_world do
      realm "Examples"
      latest "v1"
      instance_eval(&body)
    end
  end

  it "writes into the exact same @settings path a bare top-level call does" do
    qualified = build_examples_world { WorldGrowthProbe::Thing.persisted_by("Heki") { dir "data" } }
    bare = build_examples_world { persisted_by("Heki") { dir "data" } }

    expect(qualified.settings).to eq(bare.settings)
  end

  it "the bare top-level and aggregate-qualified spellings produce identical settings", :aggregate_failures do
    world = build_examples_world { WorldGrowthProbe::Thing.projected_by("SqliteProjection") { database "data/thing.sqlite3" } }

    expect(world.settings["projected_by"]).to eq(adapter: "SqliteProjection", database: "data/thing.sqlite3")
    expect(world.settings["projected_by:sqliteprojection"]).to eq(world.settings["projected_by"])
  end

  # A repeat boot in one process leaves the previous boot's chapter installed as a top-level
  # constant, so `Widgets` is a real module and only `::` reaches the world's own resolver.
  context "when a facade chapter of the same name is installed" do
    let(:chapter) do
      registry = Hecks::Runtime::Registry.new
      Hecks.with_registry(registry) do
        Hecks.bluebook("Widgets") do
          vision "an installed chapter"
          aggregate("Thing") do
            identified_by :ref
            attribute :ref, Ref
            value_object("Ref") { attribute :value, String }
            command("Make") do
              sets :ref
              emits "Made"
            end
          end
        end
      end
      Hecks::Doors::RubyDoor.chapter_module(Hecks::Runtime::Dispatcher.new(registry),
                                            registry.bluebook("Widgets"))
    end

    before { stub_const("Widgets", chapter) }

    it "records a bind on an aggregate the chapter does not declare" do
      world = build_examples_world { Widgets::Gadget.persisted_by("Heki") { dir "data" } }

      expect(world.settings["persisted_by"]).to eq(adapter: "Heki", dir: "data")
    end

    it "records a bind on an aggregate the chapter declares" do
      world = build_examples_world { Widgets::Thing.persisted_by("Heki") { dir "data" } }

      expect(world.settings["persisted_by:heki"]).to eq(adapter: "Heki", dir: "data")
    end
  end
end
