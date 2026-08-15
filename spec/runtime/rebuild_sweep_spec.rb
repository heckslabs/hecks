require "spec_helper"

# THE OUT-OF-BAND HALF OF `projects` (S12, ADR 0025 — "Consistency
# across aggregate boundaries") — proven end to end against a
# dedicated fixture, not the real corpus: banking's own Account
# declares `projects :customer_status` (real IR, real round-trip,
# real validation) but deliberately does not yet read it from any
# `given`/`ensures`/`invariant` — see that field's own comment.
RSpec.describe "the rebuild sweep" do
  FIXTURE = File.join(InMemoryDomain::ROOT, "spec/fixtures/projected_fields.bluebook")

  def boot
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(FIXTURE)
      Hecksagain::Runtime::Loader.bind_runtime(
        Hecksagain::Runtime::Dispatcher.new(registry)
      )
    end
  end

  it "leaves a projected field absent on a record no sweep has touched" do
    runtime = boot
    runtime.dispatch("ProjectedFields::Customer.Register", ref: { value: "c1" })
    runtime.dispatch("ProjectedFields::Account.Open", customer: "c1", ref: { value: "a1" })

    account = runtime.registry.repository("ProjectedFields", runtime.registry.bluebook("ProjectedFields").aggregate("Account"))
                     .find("a1")
    expect(account.key?(:customer_status)).to be(false)

    expect { runtime.dispatch("ProjectedFields::Account.CheckCustomerActive", ref: "a1") }
      .to raise_error(Hecksagain::Runtime::ProjectionAbsent, /not yet projected/)
  end

  it "copies the target's own field once swept, and a guard reads the local copy" do
    runtime = boot
    runtime.dispatch("ProjectedFields::Customer.Register", ref: { value: "c2" })
    runtime.dispatch("ProjectedFields::Account.Open", customer: "c2", ref: { value: "a2" })

    changed = Hecksagain::Runtime::RebuildSweep.call(
      runtime.registry, "ProjectedFields", runtime.registry.bluebook("ProjectedFields").aggregate("Account")
    )
    expect(changed).to eq(1)

    account = runtime.registry.repository("ProjectedFields", runtime.registry.bluebook("ProjectedFields").aggregate("Account"))
                     .find("a2")
    expect(account[:customer_status]).to eq("active")

    expect { runtime.dispatch("ProjectedFields::Account.CheckCustomerActive", ref: "a2") }
      .not_to raise_error
  end

  it "goes stale once the target moves, until the sweep runs again" do
    runtime = boot
    runtime.dispatch("ProjectedFields::Customer.Register", ref: { value: "c3" })
    runtime.dispatch("ProjectedFields::Account.Open", customer: "c3", ref: { value: "a3" })

    aggregate = runtime.registry.bluebook("ProjectedFields").aggregate("Account")
    Hecksagain::Runtime::RebuildSweep.call(runtime.registry, "ProjectedFields", aggregate)

    runtime.dispatch("ProjectedFields::Customer.Suspend", ref: "c3")

    # STALE ON PURPOSE — this is the whole point of "kept fresh by a
    # sweep rather than read live": the copy still answers "active"
    # until something runs the sweep again.
    expect { runtime.dispatch("ProjectedFields::Account.CheckCustomerActive", ref: "a3") }
      .not_to raise_error

    changed = Hecksagain::Runtime::RebuildSweep.call(runtime.registry, "ProjectedFields", aggregate)
    expect(changed).to eq(1)

    expect { runtime.dispatch("ProjectedFields::Account.CheckCustomerActive", ref: "a3") }
      .to raise_error(Hecksagain::Runtime::GivenNotMet)
  end

  it "changes nothing, and saves nothing, on a second sweep with no drift" do
    runtime = boot
    runtime.dispatch("ProjectedFields::Customer.Register", ref: { value: "c4" })
    runtime.dispatch("ProjectedFields::Account.Open", customer: "c4", ref: { value: "a4" })

    aggregate = runtime.registry.bluebook("ProjectedFields").aggregate("Account")
    expect(Hecksagain::Runtime::RebuildSweep.call(runtime.registry, "ProjectedFields", aggregate)).to eq(1)
    expect(Hecksagain::Runtime::RebuildSweep.call(runtime.registry, "ProjectedFields", aggregate)).to eq(0)
  end
end
