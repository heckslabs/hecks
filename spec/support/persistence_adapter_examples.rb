# What the journalling persistence adapters (Sqlite, Postgres, PostgresEra, Heki) all owe, written
# once and run against each. A spec supplies `adapter` and `aggregate` (the Pizzas "Order"), and
# where an example opens a second adapter, `reopened_adapter` (same store) or `other_domain_adapter`
# (same store, a different domain). Examples that name one adapter's storage stay in its own spec.

# The Pizzas "Order" fixtures every adapter spec builds its records and events from.
RSpec.shared_context "with the Pizzas Order adapter helpers" do
  def instance(id, **fields)
    built = Hecks::Runtime::Instance.new(aggregate: aggregate, id: id)
    fields.each { |name, value| built[name] = Hecks::Runtime::Value.for(aggregate, name, value) }
    built
  end

  def margherita
    instance("p1", name: { value: "Margherita" },
                   pizza: { price_cents: { cents: 1200 }, size: { value: "small" } }, status: "available")
  end

  def pizza_purchased(id, customer, at)
    Hecks::Runtime::Event.new(name: "PizzaPurchased", aggregate: "Pizza", id: id,
                              payload: { customer: customer }, occurred_at: at)
  end

  def event_summary(events) = events.map { |item| [item.name, item.id, item.payload] }
end

# The core record contract of the SQL journalling adapters (Sqlite, Postgres, PostgresEra): what
# is saved is found, every write is journaled, a delete is journaled too, events are kept per
# record, and a second adapter over the same store sees it all.
RSpec.shared_examples "a journalled record adapter" do
  def record_events_of_two_pizzas_and_an_order
    adapter.record_event(pizza_purchased("p1", "c1", "2026-01-01T00:00:00Z"))
    adapter.record_event(pizza_purchased("p2", "c2", "2026-01-01T00:00:01Z"))
    adapter.record_event(Hecks::Runtime::Event.new(name: "OrderPlaced", aggregate: "Order", id: "p1",
                                                   payload: { total: 12 }, occurred_at: "2026-01-01T00:00:02Z"))
  end

  it "saves and finds one back", :aggregate_failures do
    adapter.save(margherita)

    found = adapter.find("p1")
    expect(found.name.to_h).to eq(value: "Margherita")
    expect(found.pizza.to_h).to eq(price_cents: { cents: 1200 }, size: { value: "small" })
    expect(found.status).to eq("available")
  end

  it "round-trips a list of value objects", :aggregate_failures do
    adapter.save(instance("p1", toppings: [{ name: "Basil", amount: 3 }]))

    toppings = adapter.find("p1").toppings
    expect(toppings).to all(be_a(Hecks::Runtime::Value))
    expect(toppings.map(&:to_h)).to eq([{ name: "Basil", amount: 3 }])
  end

  it "answers nil for an id it never stored" do
    expect(adapter.find("nope")).to be_nil
  end

  it "keeps every write in the journal and reads the last one back", :aggregate_failures do
    adapter.save(instance("p1", status: "available"))
    adapter.save(instance("p1", status: "sold"))

    expect(adapter.count).to eq(1)
    expect(adapter.find("p1").status).to eq("sold")
    expect(adapter.entries.map { |entry| entry.state[:status] }).to eq(%w[available sold])
  end

  it "lists everything it holds", :aggregate_failures do
    adapter.save(instance("p1", name: { value: "Margherita" }))
    adapter.save(instance("p2", name: { value: "Bare" }))

    expect(adapter.all.map(&:id)).to contain_exactly("p1", "p2")
    expect(adapter.count).to eq(2)
  end

  it "deletes through the journal and the stored record", :aggregate_failures do
    adapter.save(instance("p1", name: { value: "Temporary" }))

    expect(adapter.delete("p1")).to be(true)
    expect(adapter.find("p1")).to be_nil
    expect(adapter.entries.last.operation).to eq("delete")
  end

  it "answers true when asked to delete an id it never held" do
    expect(adapter.delete("missing")).to be(true)
  end

  it "records and reloads domain events" do
    adapter.record_event(pizza_purchased("p1", "c1", "2026-01-01T00:00:00Z"))

    expect(event_summary(adapter.events)).to eq([["PizzaPurchased", "p1", { customer: "c1" }]])
  end

  it "reads back only one record's events, not the whole shared table" do
    record_events_of_two_pizzas_and_an_order

    expect(event_summary(adapter.events_for(aggregate: "Pizza", id: "p1"))).to eq([["PizzaPurchased", "p1", { customer: "c1" }]])
  end

  it "outlives the adapter that wrote it" do
    adapter.save(instance("p1", name: { value: "Margherita" }, status: "sold"))

    expect(reopened_adapter.find("p1").status).to eq("sold")
  end
end

# The replay checkpoint and journal compaction: an append-only table the adapter projects from.
RSpec.shared_examples "a checkpointed journal adapter" do
  describe "the replay checkpoint (bounds AppendOnly#recover!'s replay to what a restart missed)" do
    it "advances with every project, so entries_since(checkpoint) is empty right after a write" do
      adapter.save(instance("p1", status: "available"))

      expect(adapter.entries_since(adapter.checkpoint)).to eq([])
    end

    it "starts at zero for a table that has never been checkpointed" do
      expect(adapter.checkpoint).to eq(0)
    end

    it "lets entries_since skip everything at or before a given sequence" do
      adapter.save(instance("p1", status: "available"))
      first_checkpoint = adapter.checkpoint
      adapter.save(instance("p2", status: "available"))

      expect(adapter.entries_since(first_checkpoint).map(&:id)).to eq(["p2"])
    end

    it "still catches up a real gap: an entry journaled without being projected is picked up", :aggregate_failures do
      entry = Hecks::Ports::Persistence::Entry.new(operation: "save", id: "p1", state: { status: "available" })
      adapter.append(entry)
      expect(adapter.find("p1")).to be_nil

      Hecks::Ports::Persistence::AppendOnly.new(adapter).recover!

      expect(adapter.find("p1").status).to eq("available")
    end
  end

  describe "compact_entries! (deletes old journal rows a :refresh projection no longer needs)" do
    it "starts at zero when nothing has ever been compacted" do
      expect(adapter.compacted_through).to eq(0)
    end

    context "with two entries compacted through the checkpoint" do
      before do
        adapter.save(instance("p1", status: "available"))
        adapter.save(instance("p2", status: "available"))
        @through = adapter.checkpoint
      end

      it "reports how many rows it deleted" do
        expect(adapter.compact_entries!(through: @through)).to eq(2)
      end

      it "empties the journal, leaving the aggregate table untouched", :aggregate_failures do
        adapter.compact_entries!(through: @through)

        expect(adapter.entries).to eq([])
        expect(adapter.find("p1").status).to eq("available")
      end

      it "records how far it compacted" do
        adapter.compact_entries!(through: @through)

        expect(adapter.compacted_through).to eq(@through)
      end
    end

    it "leaves rows after through in the journal" do
      adapter.save(instance("p1", status: "available"))
      first = adapter.checkpoint
      adapter.save(instance("p2", status: "available"))

      adapter.compact_entries!(through: first)

      expect(adapter.entries.map(&:id)).to eq(["p2"])
    end

    context "with a first entry compacted and a second saved" do
      before do
        adapter.save(instance("p1", status: "available"))
        adapter.compact_entries!(through: adapter.checkpoint)
        adapter.save(instance("p2", status: "available"))
        @high_water = adapter.checkpoint
      end

      it "never moves compacted_through backwards" do
        [@high_water, 0].each { |through| adapter.compact_entries!(through: through) }

        expect(adapter.compacted_through).to eq(@high_water)
      end
    end
  end
end

# The optional saga-persistence capability (§2/§3/§4): a process manager's instance survives a
# restart and is kept apart per domain.
RSpec.shared_examples "a saga-persisting adapter" do
  describe "the optional saga-persistence capability (§2/§3/§4)" do
    it "saves a saga instance and reads it back through each_saga" do
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1",
                        state: "awaiting_credit", memory: { amount: 100 })

      expect(adapter.each_saga.to_a).to eq([["Onboarding", "c1", "awaiting_credit", { amount: 100 }, []]])
    end

    it "replaces on a repeated save for the same (process_manager, correlation)" do
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "start", memory: {})
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "next", memory: { step: 2 })

      expect(adapter.each_saga.to_a).to eq([["Onboarding", "c1", "next", { step: 2 }, []]])
    end

    it "deletes a saga instance" do
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "start", memory: {})
      adapter.delete_saga(process_manager: "Onboarding", correlation: "c1")

      expect(adapter.each_saga.to_a).to eq([])
    end

    it "outlives the adapter that wrote it, same as an aggregate's own state" do
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "start", memory: { a: 1 })

      expect(reopened_adapter.each_saga.to_a).to eq([["Onboarding", "c1", "start", { a: 1 }, []]])
    end

    it "isolates sagas by domain within one shared store", :aggregate_failures do
      adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "start", memory: {})
      other_domain_adapter.save_saga(process_manager: "Onboarding", correlation: "c1", state: "different", memory: {})

      expect(adapter.each_saga.to_a).to eq([["Onboarding", "c1", "start", {}, []]])
      expect(other_domain_adapter.each_saga.to_a).to eq([["Onboarding", "c1", "different", {}, []]])
    end
  end
end

# The `Item` aggregate and records the atomic_put specs put, one per adapter spec. A spec supplies
# `aggregate` (built with `item_aggregate`) and `store`, the append-only repository under test.
RSpec.shared_context "with the atomic_put Item aggregate" do
  def item_aggregate(domain, summary)
    Hecks::Bluebook::DSL::BluebookBuilder.build(domain) do
      vision summary

      aggregate "Item" do
        identified_by do
          attribute :sku, String
        end

        value_object("Label") { attribute :value, String }
        attribute :label, Label
      end
    end.aggregate("Item")
  end

  def item_labelled(label)
    Hecks::Runtime::Instance.new(
      aggregate: aggregate,
      id:        "sku-1",
      state:     { identity: { sku: "sku-1" }, label: { value: label } }
    )
  end
end

# The atomic_put contract every adapter that reports `:atomic_put` honours.
RSpec.shared_examples "an atomic_put adapter" do
  it "reports an insert for the first put of an identity" do
    expect(store.atomic_put(item_labelled("First")).status).to eq(:inserted)
  end

  it "reports a replacement for the second put of an identity" do
    store.atomic_put(item_labelled("First"))

    expect(store.atomic_put(item_labelled("Second")).status).to eq(:replaced)
  end

  it "appends every put, and finds the latest" do
    store.atomic_put(item_labelled("First"))
    store.atomic_put(item_labelled("Second"))

    expect([store.entries.size, store.find("sku-1").state[:label].to_h]).to eq([2, { value: "Second" }])
  end
end

# The dispatch-claim contract every adapter that reports `:dispatch_claims` honours: a saga
# dispatch's key is accepted once, and a claim made in a transaction that fails is released with it.
RSpec.shared_examples "a dispatch-claiming adapter" do
  it "reports the capability" do
    expect(adapter.persistence_capabilities).to include(:dispatch_claims)
  end

  it "accepts a new key once and refuses it after" do
    claims = [adapter.dispatch_claim("Carry/wire-1/WireAsked/1"), adapter.dispatch_claim("Carry/wire-1/WireAsked/1")]

    expect(claims).to eq([true, false])
  end

  it "reports whether a key was applied", :aggregate_failures do
    expect(adapter.dispatch_applied?("k1")).to be(false)

    adapter.dispatch_claim("k1")

    expect(adapter.dispatch_applied?("k1")).to be(true)
  end

  it "keeps one key's claim apart from another's" do
    adapter.dispatch_claim("k1")

    expect(adapter.dispatch_claim("k2")).to be(true)
  end

  def claim_in_failing_transaction(key)
    adapter.transaction do
      adapter.dispatch_claim(key)
      raise "the write failed"
    end
  end

  it "releases a claim made in a transaction that raised", :aggregate_failures do
    expect { claim_in_failing_transaction("k1") }.to raise_error("the write failed")
    expect(adapter.dispatch_applied?("k1")).to be(false)
  end
end
