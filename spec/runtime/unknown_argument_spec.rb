require "spec_helper"

# A command takes the arguments it declares, and no others.
#
# Pins that `normalize_args` refuses undeclared keys instead of letting a misspelled
# argument pass in silence.
RSpec.describe "an argument a command does not declare" do
  TILL = File.join(InMemoryDomain::ROOT, "spec/fixtures/till.bluebook")

  def boot_till
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(TILL)
      Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    end
  end

  it "is refused, and names itself" do
    runtime = boot_till

    expect { runtime.dispatch_flat("TillRoom::Till.OpenTill", number: { value: "till-1" }, nonsense: 1) }
      .to raise_error(Hecks::Runtime::UnknownArgument, /nonsense/)
  end

  it "is refused even when every declared argument is also present" do
    runtime = boot_till
    runtime.dispatch_flat("TillRoom::Till.OpenTill", number: { value: "till-1" })

    expect { runtime.dispatch_flat("TillRoom::Till.TakeIn", number: { value: "till-1" }, amount: { cents: 500 }, sneaky: "x") }
      .to raise_error(Hecks::Runtime::UnknownArgument, /sneaky/)
  end

  it "names every unknown argument at once, not just the first" do
    runtime = boot_till

    expect { runtime.dispatch_flat("TillRoom::Till.OpenTill", number: { value: "till-1" }, one: 1, two: 2) }
      .to raise_error(Hecks::Runtime::UnknownArgument, /one.*two|two.*one/)
  end

  it "leaves the identity keys alone" do
    # `id` and a root's reference key address the aggregate and are not declared
    # attributes; refusing them would refuse every dispatch.
    runtime = boot_till

    expect { runtime.dispatch_flat("TillRoom::Till.OpenTill", number: { value: "till-1" }) }.not_to raise_error
    expect { runtime.dispatch_flat("TillRoom::Till.Bump", number: { value: "till-1" }) }.not_to raise_error
  end
end
