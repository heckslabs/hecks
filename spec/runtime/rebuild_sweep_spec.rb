require "spec_helper"

# RebuildSweep, the out-of-band half of `projects` (ADR 0025), against a dedicated fixture.
# Seeding on save covers most cases; the sweep covers drift and bypassed writes.
RSpec.describe "the rebuild sweep" do
  FIXTURE = File.join(InMemoryDomain::ROOT, "spec/fixtures/projected_fields.bluebook")

  def boot
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(FIXTURE)
      Hecks::Runtime::Loader.bind_runtime(
        Hecks::Runtime::Dispatcher.new(registry)
      )
    end
  end

  it "seeds a projected field synchronously the moment a command saves the record" do
    runtime = boot
    runtime.dispatch_flat("ProjectedFields::Customer.Register", ref: { value: "c1" })
    runtime.dispatch_flat("ProjectedFields::Account.Open", customer: "c1", ref: { value: "a1" })

    account = runtime.registry.repository("ProjectedFields", runtime.registry.bluebook("ProjectedFields").aggregate("Account"))
                     .find("a1")
    expect(account[:customer_status]).to eq("active")

    expect { runtime.dispatch_flat("ProjectedFields::Account.CheckCustomerActive", ref: "a1") }
      .not_to raise_error
  end

  # A record written straight to the repository skips `CommandInterpreter#step_save`,
  # so seeding never ran; this is the case `ProjectionAbsent` guards.
  it "still refuses on a projected field a direct repository write never seeded" do
    runtime = boot
    runtime.dispatch_flat("ProjectedFields::Customer.Register", ref: { value: "c1b" })

    account_aggregate = runtime.registry.bluebook("ProjectedFields").aggregate("Account")
    repository = runtime.registry.repository("ProjectedFields", account_aggregate)
    bypassed = Hecks::Runtime::Instance.new(aggregate: account_aggregate, id: "a1b",
                                            state: { ref: { value: "a1b" }, customer: "c1b" })
    repository.save(bypassed)

    expect(repository.find("a1b").key?(:customer_status)).to be(false)

    expect { runtime.dispatch_flat("ProjectedFields::Account.CheckCustomerActive", ref: "a1b") }
      .to raise_error(Hecks::Runtime::ProjectionAbsent, /not yet projected/)

    changed = Hecks::Runtime::RebuildSweep.call(runtime.registry, "ProjectedFields", account_aggregate)
    expect(changed).to eq(1)

    expect { runtime.dispatch_flat("ProjectedFields::Account.CheckCustomerActive", ref: "a1b") }
      .not_to raise_error
  end

  it "goes stale once the target moves, until something saves this record again or a sweep runs" do
    runtime = boot
    runtime.dispatch_flat("ProjectedFields::Customer.Register", ref: { value: "c3" })
    runtime.dispatch_flat("ProjectedFields::Account.Open", customer: "c3", ref: { value: "a3" })

    aggregate = runtime.registry.bluebook("ProjectedFields").aggregate("Account")
    repository = runtime.registry.repository("ProjectedFields", aggregate)

    runtime.dispatch_flat("ProjectedFields::Customer.Suspend", ref: "c3")

    # Stale on purpose: Customer.Suspend does not touch Account. Read storage directly,
    # since any dispatch against Account (even CheckCustomerActive) re-seeds on save.
    expect(repository.find("a3")[:customer_status]).to eq("active")

    changed = Hecks::Runtime::RebuildSweep.call(runtime.registry, "ProjectedFields", aggregate)
    expect(changed).to eq(1)
    expect(repository.find("a3")[:customer_status]).to eq("suspended")

    expect { runtime.dispatch_flat("ProjectedFields::Account.CheckCustomerActive", ref: "a3") }
      .to raise_error(Hecks::Runtime::GivenNotMet)
  end

  it "changes nothing, and saves nothing, on a sweep with no drift — already seeded at creation" do
    runtime = boot
    runtime.dispatch_flat("ProjectedFields::Customer.Register", ref: { value: "c4" })
    runtime.dispatch_flat("ProjectedFields::Account.Open", customer: "c4", ref: { value: "a4" })

    aggregate = runtime.registry.bluebook("ProjectedFields").aggregate("Account")
    # `Open` already seeded the field, so the sweep finds nothing to change.
    expect(Hecks::Runtime::RebuildSweep.call(runtime.registry, "ProjectedFields", aggregate)).to eq(0)
    expect(Hecks::Runtime::RebuildSweep.call(runtime.registry, "ProjectedFields", aggregate)).to eq(0)
  end
end
