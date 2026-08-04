
require "spec_helper"
require "tmpdir"

# where/order_by/limit/offset used to be accepted by a read_model's DSL
# and silently ignored by every interpreter — a declared filter that
# never filtered, an order that was always id order regardless. This
# holds the fix: the options apply to the one many-side collection they
# can unambiguously mean, on both the in-memory path (Memory, and
# Postgres, which has no native read-model hook) and Sqlite's own
# projected-table path.
RSpec.describe "a read model's query options" do
  def build(&block)
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Hecks.bluebook("Ledger", &block)
      Hecks.hecksagon("Ledger") do
        Ledger::Account.persisted_by("Memory")
        Ledger::Entry.persisted_by("Memory")
      end
    end
    registry.verify!
    Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
  end

  LEDGER_DOMAIN = proc do
    vision "An account and its entries."
    generic

    aggregate "Account" do
      identified_by { ref.value }
      attribute :ref, Ref
      value_object "Ref" do
        attribute :value, String
      end

      command "CreateAccount" do
        attribute :ref, Ref
        emits "AccountCreated"
      end
    end

    aggregate "Entry" do
      identified_by { ref.value }
      attribute :ref,   Ref
      reference_to Account, as: :account
      attribute :cents, Cents
      value_object "Ref" do
        attribute :value, String
      end
      value_object "Cents" do
        attribute :value, Integer
      end

      command "CreateEntry" do
        attribute :ref,     Ref
        reference_to Account, as: :account
        attribute :cents,   Cents
        emits "EntryCreated"
      end
    end

    read_model "Statement" do
      reference_to Account
      include Account
      include Entry
      where(cents: { gt: 0 })
      order_by :cents, :desc
      limit 2
    end

    read_model "Bare" do
      reference_to Account
      include Account
      include Entry
    end
  end

  it "filters, orders, and caps the one many-side collection" do
    runtime = build(&LEDGER_DOMAIN)
    Account.create_account(ref: { value: "a1" })
    Entry.create_entry(ref: { value: "e1" }, account: "a1", cents: { value: 100 })
    Entry.create_entry(ref: { value: "e2" }, account: "a1", cents: { value: -50 })
    Entry.create_entry(ref: { value: "e3" }, account: "a1", cents: { value: 300 })
    Entry.create_entry(ref: { value: "e4" }, account: "a1", cents: { value: 200 })

    rows = runtime.query("Ledger.statement", account: "a1")
    entries = rows.first[:entries]

    expect(entries.map { |e| e[:cents][:value] }).to eq([300, 200])
  end

  it "refuses at build with zero many-side heads" do
    expect do
      build do
        vision "x"
        generic

        aggregate "Account" do
          identified_by { ref.value }
          attribute :ref, Ref
          value_object "Ref" do
            attribute :value, String
          end
        end

        read_model "Solo" do
          reference_to Account
          include Account
          where(ref: "a1")
        end
      end
    end.to raise_error(Hecksagain::Bluebook::DSL::Malformed, /includes 0 many-side aggregates, not exactly one/)
  end

  it "refuses at build with more than one many-side head" do
    expect do
      build do
        vision "x"
        generic

        aggregate "Account" do
          identified_by { ref.value }
          attribute :ref, Ref
          value_object "Ref" do
            attribute :value, String
          end
        end

        aggregate "Entry" do
          identified_by { ref.value }
          attribute :ref, Ref
          reference_to Account, as: :account
          value_object "Ref" do
            attribute :value, String
          end
        end

        aggregate "Note" do
          identified_by { ref.value }
          attribute :ref, Ref
          reference_to Account, as: :account
          value_object "Ref" do
            attribute :value, String
          end
        end

        read_model "Both" do
          reference_to Account
          include Account
          include Entry
          include Note
          limit 1
        end
      end
    end.to raise_error(Hecksagain::Bluebook::DSL::Malformed, /includes 2 many-side aggregates, not exactly one/)
  end

  it "leaves a read model with no declared options exactly as before" do
    runtime = build(&LEDGER_DOMAIN)
    Account.create_account(ref: { value: "a1" })
    Entry.create_entry(ref: { value: "e1" }, account: "a1", cents: { value: 100 })
    Entry.create_entry(ref: { value: "e2" }, account: "a1", cents: { value: -50 })

    rows = runtime.query("Ledger.bare", account: "a1")
    expect(rows.first[:entries].map { |e| e[:cents][:value] }).to contain_exactly(100, -50)
  end

  it "applies the same options through Sqlite's native projected-table path" do
    Dir.mktmpdir do |dir|
      registry = Hecksagain::Runtime::Registry.new
      Hecksagain.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecksagain/adapters/driven/sqlite.adapter"))
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Hecks.bluebook("Ledger", &LEDGER_DOMAIN)
        Hecks.hecksagon("Ledger") do
          Ledger::Account.persisted_by("SqlitePersistence")
          Ledger::Entry.persisted_by("SqlitePersistence")
        end
        Hecks.world("Ledger") do
          persisted_by("SqlitePersistence") { database File.join(dir, "ledger.db") }
        end
      end
      registry.verify!
      runtime = Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))

      Account.create_account(ref: { value: "a1" })
      Entry.create_entry(ref: { value: "e1" }, account: "a1", cents: { value: 100 })
      Entry.create_entry(ref: { value: "e2" }, account: "a1", cents: { value: -50 })
      Entry.create_entry(ref: { value: "e3" }, account: "a1", cents: { value: 300 })
      Entry.create_entry(ref: { value: "e4" }, account: "a1", cents: { value: 200 })

      rows = runtime.query("Ledger.statement", account: "a1")
      expect(rows.first[:entries].map { |e| e[:cents][:value] }).to eq([300, 200])
    end
  end
end
