require_relative "memory_ports"

# Aggregate declarations the read-model specs apply inside a bluebook with `instance_exec`. They are
# top-level constants because the DSL resolves names like `Ref` and `Account` through Object.

# An aggregate identified by a string `ref`, named by the caller.
READ_MODEL_PLAIN_AGGREGATE = lambda do |name|
  proc do
    aggregate name do
      identified_by :ref
      attribute :ref, Ref
      value_object "Ref" do
        attribute :value, String
      end
    end
  end
end

# An aggregate identified by a string `ref` that references Account, named by the caller.
READ_MODEL_LINKED_AGGREGATE = lambda do |name|
  proc do
    aggregate name do
      identified_by :ref
      attribute :ref, Ref
      reference_to Account, as: :account
      value_object "Ref" do
        attribute :value, String
      end
    end
  end
end

READ_MODEL_ACCOUNT_AGGREGATE = READ_MODEL_PLAIN_AGGREGATE.call("Account")
READ_MODEL_ENTRY_AGGREGATE = READ_MODEL_PLAIN_AGGREGATE.call("Entry")
READ_MODEL_LINKED_ENTRY_AGGREGATE = READ_MODEL_LINKED_AGGREGATE.call("Entry")
READ_MODEL_LINKED_NOTE_AGGREGATE = READ_MODEL_LINKED_AGGREGATE.call("Note")

# Boot and refusal helpers shared by the read-model interpreter specs: the Banking corpus bound to
# one adapter, a small fresh domain bound to Memory, a Sqlite-backed Banking, and a build-time
# refusal probe. Include it in an example group.
module ReadModelSpecHelpers
  BANKING_AGGREGATES = ["Customer", "Account", "ATMCard", "Transfer", "CardPayment", "ExternalTransfer",
                        "ScheduledPayment", "SafeDepositBox", "OnboardingCase"].freeze

  # Runs the block inside a fresh registry, verifies it, and answers the bound runtime.
  #
  # @return [Hecks::Runtime::Dispatcher] the runtime bound to the registry
  def boot_registry(&)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry, &)
    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  def bind_governance
    Hecks.hecksagon("Governance") do
      ::Governance::RoleAssignment.persisted_by("Memory")
      ::Governance::RoleTransition.persisted_by("Memory")
    end
  end

  def bind_banking(adapter, names)
    Hecks.hecksagon("Banking") do
      attaches "Governance"
      names.each { |name| ::Banking.const_get(name).persisted_by(adapter) }
    end
    bind_governance
  end

  # Boots the Banking corpus on one adapter, optionally reopening its bluebook with extra read models.
  #
  # @param adapter [String] the persistence adapter every aggregate is bound to
  # @param extra [Proc, nil] DSL applied to the Banking bluebook after it loads
  # @param names [Array<String>] the Banking aggregates to bind
  # @return [Hecks::Runtime::Dispatcher] the bound runtime
  def boot_banking_bundle(adapter: "Memory", extra: nil, names: BANKING_AGGREGATES)
    boot_registry do
      MemoryPorts.load!
      load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
      Hecks.bluebook("Banking", &extra) if extra
      bind_banking(adapter, names)
    end
  end

  # Boots a small fresh domain with every named aggregate on one adapter.
  def boot_memory_domain(name, body, aggregates:, adapter: "Memory")
    boot_registry do
      MemoryPorts.load!
      Hecks.bluebook(name, &body)
      Hecks.hecksagon(name) do
        aggregates.each { |aggregate| Object.const_get(name).const_get(aggregate).persisted_by(adapter) }
      end
    end
  end

  # Boots Banking on SqlitePersistence in `dir`, with the named aggregates also projected natively.
  def boot_sqlite_banking(dir, persisted:, projected: [])
    boot_registry do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/ports/projection.port")) unless projected.empty?
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/adapters/driven/sqlite.adapter"))
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
      bind_sqlite_banking(dir, persisted, projected)
    end
  end

  def bind_sqlite_banking(dir, persisted, projected)
    Hecks.hecksagon("Banking") do
      attaches "Governance"
      persisted.each { |name| ::Banking.const_get(name).persisted_by("SqlitePersistence") }
      projected.each { |name| ::Banking.const_get(name).projected_by("SqliteProjection") }
    end
    bind_governance
    bind_sqlite_world(dir, projected)
  end

  def bind_sqlite_world(dir, projected)
    Hecks.world("Banking") do
      persisted_by("SqlitePersistence") { database File.join(dir, "banking.db") }
      projected_by("SqliteProjection") { database File.join(dir, "banking-projection.db") } unless projected.empty?
    end
  end

  # A callable that builds the domain, for `expect(...).to raise_error` against a Malformed refusal.
  def domain_build(name, body)
    proc do
      Hecks.with_registry(Hecks::Runtime::Registry.new) do
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Hecks.bluebook(name, &body)
      end
    end
  end
end
