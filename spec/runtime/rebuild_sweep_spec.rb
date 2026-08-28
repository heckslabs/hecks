require "spec_helper"

# THE OUT-OF-BAND HALF OF `projects` (S12, ADR 0025 — "Consistency
# across aggregate boundaries") — proven end to end against a
# dedicated fixture, not the real corpus: banking's own Account
# declares `projects :customer_status`, which its own `given
# ("customer is active")` now reads for real (S12's own migration,
# `CommandInterpreter#seed_projected_fields` and this file's own
# updated expectations).
#
# `seed_projected_fields` (`command_interpreter.rb`) means a
# projected field is no longer absent-until-manually-swept the way
# it was before this migration — every command that SAVES a record
# with `projects` fields resolves them once, synchronously, the same
# read `RebuildSweep` itself would do. `RebuildSweep` stays the
# mechanism for the case seeding cannot cover: the TARGET moving
# AFTER this record's own last write, with nothing here to notice.
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
    runtime.dispatch("ProjectedFields::Customer.Register", ref: { value: "c1" })
    runtime.dispatch("ProjectedFields::Account.Open", customer: "c1", ref: { value: "a1" })

    account = runtime.registry.repository("ProjectedFields", runtime.registry.bluebook("ProjectedFields").aggregate("Account"))
                     .find("a1")
    expect(account[:customer_status]).to eq("active")

    expect { runtime.dispatch("ProjectedFields::Account.CheckCustomerActive", ref: "a1") }
      .not_to raise_error
  end

  # THE ONE CASE SYNCHRONOUS SEEDING CANNOT COVER: a record that
  # never went through `CommandInterpreter#step_save` at all — a
  # direct repository write, the same shape a bulk import or a
  # migration script would use. This is `ProjectionAbsent`'s real
  # job now: not "before the first save," which no longer happens,
  # but "before ANY save this runtime's own dispatch pipeline ever
  # touched."
  it "still refuses on a projected field a direct repository write never seeded" do
    runtime = boot
    runtime.dispatch("ProjectedFields::Customer.Register", ref: { value: "c1b" })

    account_aggregate = runtime.registry.bluebook("ProjectedFields").aggregate("Account")
    repository = runtime.registry.repository("ProjectedFields", account_aggregate)
    bypassed = Hecks::Runtime::Instance.new(aggregate: account_aggregate, id: "a1b",
                                            state: { ref: { value: "a1b" }, customer: "c1b" })
    repository.save(bypassed)

    expect(repository.find("a1b").key?(:customer_status)).to be(false)

    expect { runtime.dispatch("ProjectedFields::Account.CheckCustomerActive", ref: "a1b") }
      .to raise_error(Hecks::Runtime::ProjectionAbsent, /not yet projected/)

    changed = Hecks::Runtime::RebuildSweep.call(runtime.registry, "ProjectedFields", account_aggregate)
    expect(changed).to eq(1)

    expect { runtime.dispatch("ProjectedFields::Account.CheckCustomerActive", ref: "a1b") }
      .not_to raise_error
  end

  it "goes stale once the target moves, until something saves this record again or a sweep runs" do
    runtime = boot
    runtime.dispatch("ProjectedFields::Customer.Register", ref: { value: "c3" })
    runtime.dispatch("ProjectedFields::Account.Open", customer: "c3", ref: { value: "a3" })

    aggregate = runtime.registry.bluebook("ProjectedFields").aggregate("Account")
    repository = runtime.registry.repository("ProjectedFields", aggregate)

    runtime.dispatch("ProjectedFields::Customer.Suspend", ref: "c3")

    # STALE ON PURPOSE — this is the whole point of "kept fresh by a
    # seed-on-write plus a sweep for drift, rather than read live":
    # Customer.Suspend only touches Customer's own record, so Account's
    # own copy still answers "active" until SOMETHING saves this
    # Account record again. Checked directly against storage, not via
    # another dispatch — dispatching ANYTHING against this same
    # Account (even a pure read-shaped command like
    # CheckCustomerActive, which still runs step_save) would itself
    # re-seed the field before the sweep gets a chance to be the one
    # that does.
    expect(repository.find("a3")[:customer_status]).to eq("active")

    changed = Hecks::Runtime::RebuildSweep.call(runtime.registry, "ProjectedFields", aggregate)
    expect(changed).to eq(1)
    expect(repository.find("a3")[:customer_status]).to eq("suspended")

    expect { runtime.dispatch("ProjectedFields::Account.CheckCustomerActive", ref: "a3") }
      .to raise_error(Hecks::Runtime::GivenNotMet)
  end

  it "changes nothing, and saves nothing, on a sweep with no drift — already seeded at creation" do
    runtime = boot
    runtime.dispatch("ProjectedFields::Customer.Register", ref: { value: "c4" })
    runtime.dispatch("ProjectedFields::Account.Open", customer: "c4", ref: { value: "a4" })

    aggregate = runtime.registry.bluebook("ProjectedFields").aggregate("Account")
    # Already correct from `Open`'s own synchronous seed — a sweep
    # immediately after creation finds nothing to change.
    expect(Hecks::Runtime::RebuildSweep.call(runtime.registry, "ProjectedFields", aggregate)).to eq(0)
    expect(Hecks::Runtime::RebuildSweep.call(runtime.registry, "ProjectedFields", aggregate)).to eq(0)
  end
end
