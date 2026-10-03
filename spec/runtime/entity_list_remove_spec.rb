require "spec_helper"

# `remove:` on an entity-typed list matches the element by identity, coercing a scalar target
# (Ledger.Void, `sets :entries, remove: :sequence`); an inline domain keeps it self-contained.
RSpec.describe "remove: on an entity-typed list" do
  ENTITY_LIST_REMOVE_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "EntityListRemove" do
      vision "remove: on an entity-typed list, both aggregate-owned and entity-owned."
      core

      aggregate "Ledger" do
        identified_by :reference

        attribute :reference, LedgerReference
        attribute :entries,   list_of(Entry)

        value_object "LedgerReference" do
          attribute :value, String
        end

        value_object "EntrySequence" do
          attribute :value, Integer
        end

        value_object "EntryAmount" do
          attribute :cents, Integer
        end

        command "Open" do
          role "Clerk"
          attribute :reference, LedgerReference
          emits "LedgerOpened"
        end

        command "Record" do
          role "Clerk"
          reference_to Ledger
          attribute :amount, EntryAmount

          sets :entries, append: { amount: :amount }

          emits "EntryRecorded"
        end

        # THE AGGREGATE-LEVEL SHAPE THIS BUG IS ABOUT — `Ledger.Void`'s
        # own real-corpus shape (`qa/stress_domains/corrections`):
        # `remove:`'s single scalar target names the entity's own
        # identity field.
        command "Void" do
          role "Clerk"
          reference_to Ledger
          attribute :sequence, EntrySequence

          sets :entries, remove: :sequence

          emits "EntryVoided"
        end

        entity "Entry" do
          identified_by :sequence

          attribute :sequence, EntrySequence
          attribute :amount,   EntryAmount
          attribute :tags,     list_of(Tag)

          command "AddTag" do
            role "Clerk"
            attribute :label, TagLabel

            sets :tags, append: { label: :label }

            emits "TagAdded"
          end

          # THE ENTITY-OWNED SHAPE — an entity's own list, of ANOTHER
          # entity, removed by identity via `EntityElement#
          # removed_from_element` (the shared-helper twin of
          # `MutationApplier#removed` above).
          command "RemoveTag" do
            role "Clerk"
            attribute :label, TagLabel

            sets :tags, remove: :label

            emits "TagRemoved"
          end

          entity "Tag" do
            identified_by :label

            attribute :label, TagLabel
          end
        end

        value_object "TagLabel" do
          attribute :value, String
        end
      end
    end
  BLUEBOOK

  def boot
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.eval(ENTITY_LIST_REMOVE_SOURCE, TOPLEVEL_BINDING, "entity_list_remove.bluebook", 1)
      Hecks.hecksagon("EntityListRemove") do
        attaches "Governance"
        EntityListRemove::Ledger.persisted_by("Memory")
      end
      Hecks.hecksagon("Governance") do
        Governance::RoleAssignment.persisted_by("Memory")
        Governance::RoleTransition.persisted_by("Memory")
      end
    end

    registry.verify!
    Hecks::Runtime::Dispatcher.new(registry)
  end

  def ledger_repository(dispatcher)
    dispatcher.registry.repository("EntityListRemove", dispatcher.registry.bluebook("EntityListRemove").aggregate("Ledger"))
  end

  it "removes an entity element from an aggregate-owned list by its own identity, not value equality" do
    dispatcher = boot
    dispatcher.dispatch_flat("EntityListRemove::Ledger.Open", reference: { value: "l1" })
    dispatcher.dispatch_flat("EntityListRemove::Ledger.Record", reference: "l1", amount: { cents: 500 })
    dispatcher.dispatch_flat("EntityListRemove::Ledger.Record", reference: "l1", amount: { cents: 200 })

    entries = ledger_repository(dispatcher).find("l1")[:entries]
    expect(entries.map { |e| [e[:sequence].value, e[:amount].cents] }).to eq([[1, 500], [2, 200]])

    dispatcher.dispatch_flat("EntityListRemove::Ledger.Void", reference: "l1", sequence: { value: 2 })

    entries = ledger_repository(dispatcher).find("l1")[:entries]
    expect(entries.map { |e| [e[:sequence].value, e[:amount].cents] }).to eq([[1, 500]])
  end

  it "is a no-op, not an error, voiding a sequence that was never recorded" do
    dispatcher = boot
    dispatcher.dispatch_flat("EntityListRemove::Ledger.Open", reference: { value: "l2" })
    dispatcher.dispatch_flat("EntityListRemove::Ledger.Record", reference: "l2", amount: { cents: 100 })

    dispatcher.dispatch_flat("EntityListRemove::Ledger.Void", reference: "l2", sequence: { value: 999 })

    entries = ledger_repository(dispatcher).find("l2")[:entries]
    expect(entries.map { |e| e[:sequence].value }).to eq([1])
  end

  # GUARANTEED_BY_CONSTRUCTION (lib/hecks/fuzzing/properties.rb): an auto-minted identity is one
  # past the highest held (`MutationApplier#next_identity`), so a freed identity is safe to reuse.
  it "reuses a freed identity on the next auto-mint (one past the highest HELD, not size + 1)" do
    dispatcher = boot
    dispatcher.dispatch_flat("EntityListRemove::Ledger.Open", reference: { value: "l3" })
    dispatcher.dispatch_flat("EntityListRemove::Ledger.Record", reference: "l3", amount: { cents: 500 })
    dispatcher.dispatch_flat("EntityListRemove::Ledger.Record", reference: "l3", amount: { cents: 200 })
    dispatcher.dispatch_flat("EntityListRemove::Ledger.Void", reference: "l3", sequence: { value: 2 })

    dispatcher.dispatch_flat("EntityListRemove::Ledger.Record", reference: "l3", amount: { cents: 999 })

    entries = ledger_repository(dispatcher).find("l3")[:entries]
    expect(entries.map { |e| [e[:sequence].value, e[:amount].cents] }).to eq([[1, 500], [2, 999]])
  end

  it "removes an element from an ENTITY-OWNED list (an entity's own list of another entity) by identity" do
    dispatcher = boot
    dispatcher.dispatch_flat("EntityListRemove::Ledger.Open", reference: { value: "l4" })
    dispatcher.dispatch_flat("EntityListRemove::Ledger.Record", reference: "l4", amount: { cents: 500 })
    dispatcher.dispatch_flat("EntityListRemove::Ledger.Entry.AddTag", reference: "l4", sequence: { value: 1 },
                        label: { value: "urgent" })
    dispatcher.dispatch_flat("EntityListRemove::Ledger.Entry.AddTag", reference: "l4", sequence: { value: 1 },
                        label: { value: "reviewed" })

    entry = ledger_repository(dispatcher).find("l4")[:entries].first
    expect(entry[:tags].map { |t| t[:label].value }).to eq(%w[urgent reviewed])

    dispatcher.dispatch_flat("EntityListRemove::Ledger.Entry.RemoveTag", reference: "l4", sequence: { value: 1 },
                        label: { value: "urgent" })

    entry = ledger_repository(dispatcher).find("l4")[:entries].first
    expect(entry[:tags].map { |t| t[:label].value }).to eq(["reviewed"])
  end
end
