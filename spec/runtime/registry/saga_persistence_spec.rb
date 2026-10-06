require "spec_helper"

# Registry#saga_persistence resolves which adapter (or the no-op fallback) holds a domain's
# saga state; adapter round-trips are covered in their own specs.
RSpec.describe "Registry#saga_persistence" do
  def fresh_registry
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
    end
    registry
  end

  def memory_registry
    registry = fresh_registry
    Hecks.with_registry(registry) { Kernel.load(InMemoryDomain::MEMORY_ADAPTER) }
    registry
  end

  # One block per line: the Prism adapter finds a block by start line alone, so nested
  # blocks sharing a line would extract the outermost one.
  def declare_thing(registry, domain)
    Hecks.with_registry(registry) do
      Hecks.bluebook(domain) do
        aggregate("Thing") do
          identified_by :thing_id
        end
      end
    end
  end

  def bind_thing_to_memory(registry, domain)
    Hecks.with_registry(registry) do
      Hecks.hecksagon(domain) { Object.const_get(domain)::Thing.persisted_by("Memory") }
    end
  end

  def memory_bound_registry(domain)
    registry = memory_registry
    declare_thing(registry, domain)
    bind_thing_to_memory(registry, domain)
    registry
  end

  # "First" is bound to Memory and "Second" has no hecksagon at all.
  def verified_two_domain_registry
    registry = memory_bound_registry("First")
    declare_thing(registry, "Second")
    registry.verify!
    registry
  end

  it "resolves to the no-op store for a domain with no hecksagon at all" do
    registry = fresh_registry
    declare_thing(registry, "Undeclared")

    expect(registry.saga_persistence("Undeclared")).to be(Hecks::Ports::Persistence::NULL_SAGA_STORE)
  end

  it "resolves to the no-op store for a domain no bluebook was ever loaded for" do
    registry = Hecks::Runtime::Registry.new

    expect(registry.saga_persistence("Nonexistent")).to be(Hecks::Ports::Persistence::NULL_SAGA_STORE)
  end

  it "resolves to the no-op store when the resolved adapter (Memory) doesn't implement the capability" do
    registry = memory_bound_registry("Hexed")
    registry.verify!

    expect(registry.saga_persistence("Hexed")).to be(Hecks::Ports::Persistence::NULL_SAGA_STORE)
  end

  # An unbound anchor aggregate makes BindingPolicy.resolve refuse; saga persistence must
  # degrade to the no-op store instead. verify! is skipped because it raises on this gap.
  it "resolves to the no-op store, not a raised error, when the anchor aggregate has no bind at all" do
    registry = fresh_registry
    declare_thing(registry, "Unbound")
    Hecks.with_registry(registry) { Hecks.hecksagon("Unbound") { nil } }

    expect(registry.saga_persistence("Unbound")).to be(Hecks::Ports::Persistence::NULL_SAGA_STORE)
  end

  it "resolves independently per domain", :aggregate_failures do
    registry = verified_two_domain_registry

    expect(%w[First Second].map { |domain| registry.saga_persistence(domain) })
      .to all(be(Hecks::Ports::Persistence::NULL_SAGA_STORE))
    # Guards against one memoized slot keyed by the registry instead of the domain name.
    expect(registry.instance_variable_get(:@saga_persistence).keys).to contain_exactly("First", "Second")
  end
end
