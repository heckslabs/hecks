require "spec_helper"

# `Registry#saga_persistence` — the resolution half of §2's saga-
# persistence capability (the adapter-side `save_saga`/`delete_saga`/
# `each_saga` implementations land per adapter in §3/§4 and get their
# own dedicated round-trip specs there; this proves the RESOLUTION
# logic itself: which adapter instance (or the no-op fallback) a
# domain's saga state would persist through, entirely independent of
# whether any real adapter answers the capability yet).
RSpec.describe "Registry#saga_persistence" do
  def fresh_registry
    registry = Hecksagain::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
    end
    registry
  end

  # `Ports::Extraction`'s Prism adapter locates a block's own source by
  # (file, START LINE) alone (`Adapters::Prism#block_node_at`) — nesting
  # `identified_by`'s block on the SAME LINE as its own enclosing
  # `aggregate`/`bluebook` blocks makes all three BlockNodes share one
  # start line, and the line-only lookup returns the OUTERMOST match
  # instead, extracting far more source than intended. One block per
  # line, matching `dsl_spec.rb`'s own `build_aggregate` helper (the
  # same reason it's shaped that way there).
  def declare_thing(registry, domain)
    Hecks.with_registry(registry) do
      Hecks.bluebook(domain) do
        aggregate("Thing") do
          identified_by :thing_id
        end
      end
    end
  end

  it "resolves to the no-op store for a domain with no hecksagon at all" do
    registry = fresh_registry
    declare_thing(registry, "Undeclared")

    expect(registry.saga_persistence("Undeclared")).to be(Hecksagain::Ports::Persistence::NULL_SAGA_STORE)
  end

  it "resolves to the no-op store for a domain no bluebook was ever loaded for" do
    registry = Hecksagain::Runtime::Registry.new

    expect(registry.saga_persistence("Nonexistent")).to be(Hecksagain::Ports::Persistence::NULL_SAGA_STORE)
  end

  it "resolves to the no-op store when the resolved adapter (Memory) doesn't implement the capability" do
    registry = fresh_registry
    Hecks.with_registry(registry) { Kernel.load(InMemoryDomain::MEMORY_ADAPTER) }
    declare_thing(registry, "Hexed")
    Hecks.with_registry(registry) { Hecks.hecksagon("Hexed") { Hexed::Thing.persisted_by("Memory") } }
    registry.verify!

    expect(registry.saga_persistence("Hexed")).to be(Hecksagain::Ports::Persistence::NULL_SAGA_STORE)
  end

  # THE RESCUE PATH — a hecksagon exists (this domain's wiring IS being
  # decided explicitly) but its own anchor aggregate declares no bind
  # at all, which `Ports::Persistence::BindingPolicy.resolve` refuses
  # loudly (`missing_binding`) rather than silently defaulting. Saga
  # persistence degrades to the same no-op default an unbound domain
  # gets instead of raising out of what would otherwise be a
  # successful dispatch — deliberately NOT calling `verify!` here,
  # since `verify!` would itself raise on this exact gap (by design,
  # for a domain's own real persistence) and this test is about what
  # `saga_persistence` alone does when asked anyway.
  it "resolves to the no-op store, not a raised error, when the anchor aggregate has no bind at all" do
    registry = fresh_registry
    declare_thing(registry, "Unbound")
    Hecks.with_registry(registry) { Hecks.hecksagon("Unbound") {} }

    expect(registry.saga_persistence("Unbound")).to be(Hecksagain::Ports::Persistence::NULL_SAGA_STORE)
  end

  it "memoizes the resolution — the same domain always answers the same object" do
    registry = fresh_registry
    declare_thing(registry, "Undeclared")

    first  = registry.saga_persistence("Undeclared")
    second = registry.saga_persistence("Undeclared")

    expect(first).to be(second)
  end

  it "resolves independently per domain" do
    registry = fresh_registry
    Hecks.with_registry(registry) { Kernel.load(InMemoryDomain::MEMORY_ADAPTER) }
    declare_thing(registry, "First")
    Hecks.with_registry(registry) { Hecks.hecksagon("First") { First::Thing.persisted_by("Memory") } }
    declare_thing(registry, "Second")
    registry.verify!

    expect(registry.saga_persistence("First")).to be(Hecksagain::Ports::Persistence::NULL_SAGA_STORE)
    expect(registry.saga_persistence("Second")).to be(Hecksagain::Ports::Persistence::NULL_SAGA_STORE)
    # Distinct calls, not accidentally sharing one memoized slot keyed
    # wrong (e.g. by the registry rather than the domain name).
    expect(registry.instance_variable_get(:@saga_persistence).keys).to contain_exactly("First", "Second")
  end
end
