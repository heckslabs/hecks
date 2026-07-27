# frozen_string_literal: true

require "spec_helper"

# THE CLOSED SET, pinned against the REAL banking bluebook — loaded without
# its hecksagon, so every aggregate takes the Memory default and the spec does
# no IO. `one_of` came over from Hecks and rode the IR as a declared SHAPE
# without ever being a GATE — member rows nobody judged, in both runtimes.
# Construction now judges the DISCRIMINANT (the first declared attribute)
# against the member rows before the invariants get a word, and the same door
# judges an OBJECT payload's invariants — the path Rust used to wave through
# unexamined while Ruby refused.
#
# The wordings here are the parity contract : Rust must refuse in exactly
# these characters or stage 2 splits.
RSpec.describe "one_of" do
  ONE_OF_BANKING = File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook")

  def boot_banking
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(ONE_OF_BANKING)
      Hecksagain::Runtime::Loader.bind_runtime(
        Hecksagain::Runtime::Dispatcher.new(registry)
      )
    end
  end

  it "admits a declared member" do
    runtime = boot_banking

    expect do
      runtime.dispatch("Banking::Account.Open", id: "a1", customer: "c", number: "ACC-1",
                                                kind: "savings", daily_limit: 10_000)
    end.not_to raise_error
  end

  it "refuses a value outside the set, naming the set" do
    runtime = boot_banking

    expect do
      runtime.dispatch("Banking::Account.Open", id: "a1", customer: "c", number: "ACC-1",
                                                kind: "gold", daily_limit: 10_000)
    end.to raise_error(Hecksagain::Runtime::InvariantViolation,
                       'AccountKind admits "current", "savings", "reserve" — got "gold"')
  end

  it "judges an object payload's invariants at the same door" do
    runtime = boot_banking

    expect do
      runtime.dispatch("Banking::Customer.Register",
                       reference: "CUST-0009",
                       name: { given: "No", family: "Route" },
                       email: { address: "nowhere" })
    end.to raise_error(Hecksagain::Runtime::InvariantViolation,
                       'EmailAddress invariant violated — an address routes somewhere (given {"address":"nowhere"})')
  end
end
