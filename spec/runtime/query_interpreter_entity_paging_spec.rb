require "spec_helper"

# H7 — QueryInterpreter's ENTITY engine (`entity_rows`, the only engine
# entity/sub-list queries have) still had two of the three bugs the audit
# named, after `#interpret`/`#reference_interpret` had already picked up
# their own offset fix (see query_interpreter_offset_spec.rb):
#
#   1. `entity_rows` applied `limit` but never read `declared.offset` at
#      all — a declared offset on an entity query silently vanished,
#      always answering page one however many pages were asked for.
#   2. `element_where_holds?` read `element[clause.field.to_sym]` instead
#      of walking `FieldPath.dig` — a dotted `where` (`where "price.cents"
#      > 0`) is never a real single key, so it read `nil` for every
#      element and (correctly, per NullPolicy) excluded every row —
#      an entity query with a dotted where silently answered `[]`.
#
# A THIRD, sibling bug lived one level up: the plain aggregate-level
# `ordered` (used by `#interpret`/`#reference_interpret`, the reference/
# no-native-hook engine) read `record[field]` directly too — a dotted
# `order_by` on an ORDINARY (non-entity) query sorted by all-nil, so two
# records with different dotted-field values landed in whatever order the
# identity tier alone decided (here: dispatch/creation order), not the
# declared order.
RSpec.describe "QueryInterpreter — entity offset and dotted where/order_by" do
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

            # A DOTTED where AND a dotted order_by, on the ONLY engine
            # entity queries have — element_where_holds? used to answer
            # `[]` for this whatever the data, and offset was never read.
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

          # A DOTTED order_by on an ORDINARY, aggregate-level query —
          # the reference engine's OWN `ordered` used to read
          # `record[field]` directly and land on nil for every row.
          query "ByFeaturedPrice" do
            order_by :"featured_price.cents"
          end
        end
      end

      Hecks.hecksagon("EntityPaging") { ::EntityPaging::Board.persisted_by("Memory") }
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) do
    boot.tap do |bound|
      bound.dispatch("EntityPaging::Board.Register", name: { value: "b1" }, featured_price: { cents: 500 })
      bound.dispatch("EntityPaging::Board.Register", name: { value: "b2" }, featured_price: { cents: 100 })
      bound.dispatch("EntityPaging::Board.Register", name: { value: "b3" }, featured_price: { cents: 300 })

      [10, 20, 30, 40, 50].each do |cents|
        bound.dispatch("EntityPaging::Board.AddItem", name: { value: "b1" }, price: { cents: cents })
      end
    end
  end

  def item_cents = runtime.query("EntityPaging::Board.Item.ByPrice").map { |row| row[:price][:cents] }

  it "matches a dotted where against every element, not just nil" do
    # The bug answered [] outright — every element read nil off a key
    # that was never real (`element[:"price.cents"]`), and nil never
    # satisfies `gt`.
    expect(item_cents).not_to be_empty
  end

  it "skips before it takes on an entity query, the same as an aggregate one" do
    # Ascending by price.cents: 10, 20, 30, 40, 50 — offset 1 skips the
    # 10, limit 2 then takes the next two. The bug (offset never read)
    # would have answered [10, 20] instead.
    expect(item_cents).to eq([20, 30])
  end

  it "orders a dotted field on an ORDINARY query too, not just an entity one" do
    names = runtime.query("EntityPaging::Board.ByFeaturedPrice").map { |row| row[:name][:value] }
    # Ascending by featured_price.cents: b2 (100), b3 (300), b1 (500).
    # The bug (`record[field]` instead of FieldPath.dig) sorted by
    # nil for every row, so the identity tier alone decided — creation
    # order, b1/b2/b3.
    expect(names).to eq(%w[b2 b3 b1])
  end

  it "the reference engine (the fuzzer's own oracle) agrees" do
    names = runtime.reference_query("EntityPaging::Board.ByFeaturedPrice").map { |row| row[:name][:value] }
    expect(names).to eq(%w[b2 b3 b1])
  end
end
