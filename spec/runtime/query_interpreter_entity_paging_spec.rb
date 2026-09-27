require "spec_helper"

# Pins the entity engine's offset, dotted where, and dotted order_by: each reads
# through FieldPath.dig, and a declared offset is applied before limit.
RSpec.describe "QueryInterpreter — entity offset and dotted where/order_by" do
  # One inline fixture domain; splitting it would scatter a single declaration.
  # rubocop:disable-next Metrics/AbcSize, Metrics/MethodLength
  def boot
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      Hecks.bluebook "EntityPaging" do
        aggregate "Board" do
          attribute :name,           BoardName
          attribute :featured_price, Price
          attribute :items,          list_of(Item)

          identified_by :name

          value_object("BoardName") { attribute :value, String }
          value_object("Price") { attribute :cents, Integer }
          value_object("ItemSequence") do
            attribute :value, Integer
            invariant("a sequence is positive") { value.positive? }
          end

          entity "Item" do
            attribute :sequence, ItemSequence
            identified_by :sequence
            attribute :price, Price

            # Dotted where and order_by on the entity engine, with offset.
            query "ByPrice" do
              where("price.cents": { gt: 0 })
              order_by :"price.cents"
              limit 2
              offset 1
            end
          end

          command "Register" do
            attribute :name,           BoardName
            attribute :featured_price, Price
            sets :name
            sets :featured_price
            emits "Registered"
          end

          command "AddItem" do
            reference_to Board
            attribute :price, Price
            sets :items, append: { price: :price }
            emits "ItemAdded"
          end

          # Dotted order_by on an aggregate-level query (reference engine).
          query "ByFeaturedPrice" do
            order_by :"featured_price.cents"
          end
        end
      end

      Hecks.hecksagon("EntityPaging") { EntityPaging::Board.persisted_by("Memory") }
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) do
    boot.tap do |bound|
      bound.dispatch_flat("EntityPaging::Board.Register", name: { value: "b1" }, featured_price: { cents: 500 })
      bound.dispatch_flat("EntityPaging::Board.Register", name: { value: "b2" }, featured_price: { cents: 100 })
      bound.dispatch_flat("EntityPaging::Board.Register", name: { value: "b3" }, featured_price: { cents: 300 })

      [10, 20, 30, 40, 50].each do |cents|
        bound.dispatch_flat("EntityPaging::Board.AddItem", name: { value: "b1" }, price: { cents: cents })
      end
    end
  end

  def item_cents = runtime.query("EntityPaging::Board.Item.ByPrice").map { |row| row[:price][:cents] }

  it "matches a dotted where against every element, not just nil" do
    # A flat key lookup reads nil for every element, and nil never satisfies `gt`.
    expect(item_cents).not_to be_empty
  end

  it "skips before it takes on an entity query, the same as an aggregate one" do
    # Ascending 10..50: offset 1 skips the 10, limit 2 takes 20 and 30.
    expect(item_cents).to eq([20, 30])
  end

  it "orders a dotted field on an ORDINARY query too, not just an entity one" do
    names = runtime.query("EntityPaging::Board.ByFeaturedPrice").map { |row| row[:name][:value] }
    # Ascending by featured_price.cents: b2 (100), b3 (300), b1 (500), not creation order.
    expect(names).to eq(%w[b2 b3 b1])
  end

  it "the reference engine (the fuzzer's own oracle) agrees" do
    names = runtime.reference_query("EntityPaging::Board.ByFeaturedPrice").map { |row| row[:name][:value] }
    expect(names).to eq(%w[b2 b3 b1])
  end
end
