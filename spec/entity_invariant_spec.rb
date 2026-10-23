require "spec_helper"

# `EntityBuilder#invariant` reading an optional field a piece was given no value for: it reads nil,
# so the rule admits the piece. That a piece's invariant is checked and refuses is held by
# spec/categories/refusal_kinds_spec.rb.
RSpec.describe "a piece's own invariant, checked against every instance the aggregate holds" do
  BANKING_BLUEBOOK = InMemoryDomain::BANKING_BLUEBOOK_DIR unless defined?(BANKING_BLUEBOOK)

  def boot
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      load_bluebook_files(BANKING_BLUEBOOK)
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end
  end

  def rent_box(runtime)
    runtime.dispatch_flat("Banking::Customer.Register", reference: { value: "c1" },
                     name: { given: "A", family: "One" }, email: { address: "a@example.com" })
    runtime.dispatch_flat("Banking::SafeDepositBox.Rent", customer: "c1",
                     branch_code: { value: "DOWNTOWN" }, box_number: { value: 1 },
                     size: { value: "small" })
  end

  def rented_runtime = boot.tap { |runtime| rent_box(runtime) }

  def log_visit(runtime, **note)
    runtime.dispatch_flat("Banking::SafeDepositBox.LogVisit", branch_code: { value: "DOWNTOWN" }, box_number: { value: 1 },
                                                               date: { value: "2026-08-16" }, sequence: { value: 1 }, **note)
  end

  it "accepts a visit with no note at all — optional stays optional" do
    expect { log_visit(rented_runtime) }.not_to raise_error
  end
end
