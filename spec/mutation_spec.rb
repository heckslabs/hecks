
require "spec_helper"

RSpec.describe "then_set arithmetic" do
  TILL_BLUEBOOK = File.join(InMemoryDomain::ROOT, "spec/fixtures/till.bluebook")

  def boot_till
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(TILL_BLUEBOOK)
      Hecksagain::Runtime::Loader.bind_runtime(
        Hecksagain::Runtime::Dispatcher.new(registry)
      )
    end
  end

  it "increments from the declared default, and keeps counting" do
    runtime = boot_till
    runtime.dispatch("TillRoom::Till.OpenTill", id: "till-1")
    runtime.dispatch("TillRoom::Till.TakeIn", id: "till-1", amount: 10_000)
    runtime.dispatch("TillRoom::Till.TakeIn", id: "till-1", amount: 2_500)

    expect(TillRoom::Till.find("till-1").balance).to eq(12_500)
  end

  it "decrements, and the running balance is exact" do
    runtime = boot_till
    runtime.dispatch("TillRoom::Till.OpenTill", id: "till-1")
    runtime.dispatch("TillRoom::Till.TakeIn", id: "till-1", amount: 10_000)
    runtime.dispatch("TillRoom::Till.PayOut", id: "till-1", amount: 2_500)

    expect(TillRoom::Till.find("till-1").balance).to eq(7_500)
  end

  it "increments by a literal when the bluebook says a number" do
    runtime = boot_till
    runtime.dispatch("TillRoom::Till.OpenTill", id: "till-1")
    runtime.dispatch("TillRoom::Till.Bump", id: "till-1")

    expect(TillRoom::Till.find("till-1").balance).to eq(500)
  end

  it "refuses a non-Integer amount loudly, leaving the balance untouched" do
    runtime = boot_till
    runtime.dispatch("TillRoom::Till.OpenTill", id: "till-1")
    runtime.dispatch("TillRoom::Till.TakeIn", id: "till-1", amount: 10_000)

    expect { runtime.dispatch("TillRoom::Till.TakeIn", id: "till-1", amount: "lots") }
      .to raise_error(Hecksagain::Runtime::TypeMismatch,
                      'increment of balance needs an Integer, got "lots"')

    expect(TillRoom::Till.find("till-1").balance).to eq(10_000)
  end

  it "writes an appended literal as itself, beside the argument fields" do
    runtime = boot_till
    runtime.dispatch("TillRoom::Till.OpenTill", id: "till-1")
    runtime.dispatch("TillRoom::Till.TakeIn", id: "till-1", amount: 10_000)
    runtime.dispatch("TillRoom::Till.PayOut", id: "till-1", amount: 2_500)

    expect(TillRoom::Till.find("till-1").marks).to eq([
      { amount: 10_000, direction: "in" },
      { amount: 2_500,  direction: "out" }
    ])
  end
end
