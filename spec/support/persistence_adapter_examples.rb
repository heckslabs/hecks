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
