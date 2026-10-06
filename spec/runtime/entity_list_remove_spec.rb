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

  def bind_hecksagons
    Hecks.hecksagon("EntityListRemove") do
      attaches "Governance"
      EntityListRemove::Ledger.persisted_by("Memory")
    end
    Hecks.hecksagon("Governance") do
      Governance::RoleAssignment.persisted_by("Memory")
      Governance::RoleTransition.persisted_by("Memory")
    end
  end

  def load_memory_stack
    Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
    Kernel.load(InMemoryDomain::EXTRACTION_PORT)
    Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
    Kernel.load(InMemoryDomain::PRISM_ADAPTER)
  end

  def boot
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      load_memory_stack
      Kernel.eval(ENTITY_LIST_REMOVE_SOURCE, TOPLEVEL_BINDING, "entity_list_remove.bluebook", 1)
      bind_hecksagons
    end

    registry.verify!
    Hecks::Runtime::Dispatcher.new(registry)
  end

  def ledger_repository(dispatcher)
    dispatcher.registry.repository("EntityListRemove", dispatcher.registry.bluebook("EntityListRemove").aggregate("Ledger"))
  end

  def entries_of(dispatcher, reference) = ledger_repository(dispatcher).find(reference)[:entries]

  def sequence_and_cents(entries) = entries.map { |e| [e[:sequence].value, e[:amount].cents] }

  def tag_labels(entry) = entry[:tags].map { |t| t[:label].value }

  def ledger(dispatcher, verb, **args) = dispatcher.dispatch_flat("EntityListRemove::Ledger.#{verb}", **args)

  def record(dispatcher, reference, cents) = ledger(dispatcher, "Record", reference: reference, amount: { cents: cents })

  def void(dispatcher, reference, sequence) = ledger(dispatcher, "Void", reference: reference, sequence: { value: sequence })

  # A ledger holding entries of 500 and 200 cents (sequences 1 and 2).
  def ledger_with_two_entries(reference)
    dispatcher = boot
    ledger(dispatcher, "Open", reference: { value: reference })
    record(dispatcher, reference, 500)
    record(dispatcher, reference, 200)
    dispatcher
  end

  def add_tag(dispatcher, reference, label)
    ledger(dispatcher, "Entry.AddTag", reference: reference, sequence: { value: 1 }, label: { value: label })
  end

  it "removes an entity element from an aggregate-owned list by its own identity, not value equality", :aggregate_failures do
    dispatcher = ledger_with_two_entries("l1")
    expect(sequence_and_cents(entries_of(dispatcher, "l1"))).to eq([[1, 500], [2, 200]])

    void(dispatcher, "l1", 2)

    expect(sequence_and_cents(entries_of(dispatcher, "l1"))).to eq([[1, 500]])
  end

  it "is a no-op, not an error, voiding a sequence that was never recorded" do
    dispatcher = ledger_with_two_entries("l2")

    void(dispatcher, "l2", 999)

    expect(entries_of(dispatcher, "l2").map { |e| e[:sequence].value }).to eq([1, 2])
  end

  # GUARANTEED_BY_CONSTRUCTION (lib/hecks/fuzzing/properties.rb): an auto-minted identity is one
  # past the highest held (`MutationApplier#next_identity`), so a freed identity is safe to reuse.
  it "reuses a freed identity on the next auto-mint (one past the highest HELD, not size + 1)" do
    dispatcher = ledger_with_two_entries("l3")
    void(dispatcher, "l3", 2)

    record(dispatcher, "l3", 999)

    expect(sequence_and_cents(entries_of(dispatcher, "l3"))).to eq([[1, 500], [2, 999]])
  end

  it "removes an element from an ENTITY-OWNED list (an entity's own list of another entity) by identity", :aggregate_failures do
    dispatcher = ledger_with_two_entries("l4")
    %w[urgent reviewed].each { |label| add_tag(dispatcher, "l4", label) }
    expect(tag_labels(entries_of(dispatcher, "l4").first)).to eq(%w[urgent reviewed])

    ledger(dispatcher, "Entry.RemoveTag", reference: "l4", sequence: { value: 1 }, label: { value: "urgent" })

    expect(tag_labels(entries_of(dispatcher, "l4").first)).to eq(["reviewed"])
  end
end
