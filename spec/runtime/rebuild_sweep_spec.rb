require "spec_helper"

# RebuildSweep, the out-of-band half of `projects` (ADR 0025), against a dedicated fixture.
# Seeding on save covers most cases; the sweep covers drift and bypassed writes.
RSpec.describe "the rebuild sweep" do
  REBUILD_SWEEP_FIXTURE = File.join(InMemoryDomain::ROOT, "spec/fixtures/projected_fields.bluebook")

  def boot
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(REBUILD_SWEEP_FIXTURE)
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end
  end

  let(:runtime) { boot }
  let(:account_aggregate) { runtime.registry.bluebook("ProjectedFields").aggregate("Account") }
  let(:repository) { runtime.registry.repository("ProjectedFields", account_aggregate) }

  # A customer and one account of theirs, opened through commands so the field is seeded on save.
  def open_customer_account(customer, account)
    runtime.dispatch_flat("ProjectedFields::Customer.Register", ref: { value: customer })
    runtime.dispatch_flat("ProjectedFields::Account.Open", customer: customer, ref: { value: account })
  end

  # Suspends the customer after the account was seeded, which does not touch the account.
  def open_account_of_suspended_customer(customer, account)
    open_customer_account(customer, account)
    runtime.dispatch_flat("ProjectedFields::Customer.Suspend", ref: customer)
  end

  def check_active(account) = runtime.dispatch_flat("ProjectedFields::Account.CheckCustomerActive", ref: account)

  def sweep = Hecks::Runtime::RebuildSweep.call(runtime.registry, "ProjectedFields", account_aggregate)

  # A record written straight to the repository skips `CommandInterpreter#step_save`,
  # so seeding never ran; this is the case `ProjectionAbsent` guards.
  def bypassed_account
    runtime.dispatch_flat("ProjectedFields::Customer.Register", ref: { value: "c1b" })
    repository.save(
      Hecks::Runtime::Instance.new(aggregate: account_aggregate, id: "a1b", state: { ref: { value: "a1b" }, customer: "c1b" })
    )
  end

  it "seeds a projected field synchronously the moment a command saves the record", :aggregate_failures do
    open_customer_account("c1", "a1")

    expect(repository.find("a1")[:customer_status]).to eq("active")
    expect { check_active("a1") }.not_to raise_error
  end

  it "does not seed a projected field a direct repository write bypassed" do
    bypassed_account

    expect(repository.find("a1b").key?(:customer_status)).to be(false)
  end

  it "still refuses on a projected field a direct repository write never seeded" do
    bypassed_account

    expect { check_active("a1b") }.to raise_error(Hecks::Runtime::ProjectionAbsent, /not yet projected/)
  end

  it "seeds a bypassed record when the sweep runs, so the command stops refusing", :aggregate_failures do
    bypassed_account

    expect(sweep).to eq(1)
    expect { check_active("a1b") }.not_to raise_error
  end

  it "goes stale once the target moves, until something saves this record again or a sweep runs", :aggregate_failures do
    open_account_of_suspended_customer("c3", "a3")

    # Stale on purpose: Customer.Suspend does not touch Account. Read storage directly,
    # since any dispatch against Account (even CheckCustomerActive) re-seeds on save.
    expect(repository.find("a3")[:customer_status]).to eq("active")
    expect(sweep).to eq(1)
    expect(repository.find("a3")[:customer_status]).to eq("suspended")
    expect { check_active("a3") }.to raise_error(Hecks::Runtime::GivenNotMet)
  end

  it "changes nothing, and saves nothing, on a sweep with no drift — already seeded at creation", :aggregate_failures do
    open_customer_account("c4", "a4")

    # `Open` already seeded the field, so the sweep finds nothing to change.
    expect(sweep).to eq(0)
    expect(sweep).to eq(0)
  end

  context "when the remote field is a single-field value object" do
    SINGLE_FIELD_FIXTURE = File.join(InMemoryDomain::ROOT, "spec/fixtures/projected_single_field.bluebook")

    def single_runtime
      @single_runtime ||= begin
        registry = Hecks::Runtime::Registry.new
        Hecks.with_registry(registry) do
          [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
           InMemoryDomain::PRISM_ADAPTER, SINGLE_FIELD_FIXTURE].each { |path| Kernel.load(path) }
          Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
        end
      end
    end

    def booking_aggregate = single_runtime.registry.bluebook("ProjectedSingleField").aggregate("Booking")

    def booking_repository = single_runtime.registry.repository("ProjectedSingleField", booking_aggregate)

    def book_event(starts_at)
      single_runtime.dispatch_flat("ProjectedSingleField::Event.Schedule", ref: "e1", starts_at: starts_at)
      single_runtime.dispatch_flat("ProjectedSingleField::Booking.Open", event: "e1", ref: "b1")
    end

    def single_sweep
      Hecks::Runtime::RebuildSweep.call(single_runtime.registry, "ProjectedSingleField", booking_aggregate)
    end

    it "seeds the unwrapped scalar when a command saves the record" do
      book_event(100)

      expect(booking_repository.find("b1")[:starts_at]).to eq(100)
    end

    it "keeps the copy current when a sweep runs after the source moves", :aggregate_failures do
      book_event(100)
      single_runtime.dispatch_flat("ProjectedSingleField::Event.Reschedule", ref: "e1", starts_at: 250)

      expect(single_sweep).to eq(1)
      expect(booking_repository.find("b1")[:starts_at]).to eq(250)
    end
  end
end
