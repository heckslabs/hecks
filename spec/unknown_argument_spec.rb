
require "spec_helper"

# A command takes the arguments it declares, and no others.
#
# `normalize_args` walked the command's DECLARED attributes over a copy of the
# payload, so anything the command did not declare simply rode along untouched
# and was never looked at again. A misspelled argument was accepted in silence
# and did nothing.
#
# Found by renaming a field in the language: spec/meta_rules_spec kept dispatching
# the old `identity:` long after the attribute became `identified_by`, and the
# suite stayed green. A rename that leaves every caller wrong is supposed to be
# the easiest kind of mistake to catch.
RSpec.describe "an argument a command does not declare" do
  TILL = File.join(InMemoryDomain::ROOT, "spec/fixtures/till.bluebook")

  def boot_till
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(TILL)
      Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
    end
  end

  it "is refused, and names itself" do
    runtime = boot_till

    expect { runtime.dispatch("TillRoom::Till.OpenTill", id: "till-1", nonsense: 1) }
      .to raise_error(Hecksagain::Runtime::UnknownArgument, /nonsense/)
  end

  it "is refused even when every declared argument is also present" do
    runtime = boot_till
    runtime.dispatch("TillRoom::Till.OpenTill", id: "till-1")

    expect { runtime.dispatch("TillRoom::Till.TakeIn", id: "till-1", amount: { cents: 500 }, sneaky: "x") }
      .to raise_error(Hecksagain::Runtime::UnknownArgument, /sneaky/)
  end

  it "names every unknown argument at once, not just the first" do
    runtime = boot_till

    expect { runtime.dispatch("TillRoom::Till.OpenTill", id: "till-1", one: 1, two: 2) }
      .to raise_error(Hecksagain::Runtime::UnknownArgument, /one.*two|two.*one/)
  end

  it "leaves the identity keys alone" do
    # `id` is how a command addresses its aggregate, and a command that reaches
    # through a root addresses it by that root's reference key. Neither is a
    # declared attribute, and refusing them would refuse every dispatch there is.
    runtime = boot_till

    expect { runtime.dispatch("TillRoom::Till.OpenTill", id: "till-1") }.not_to raise_error
    expect { runtime.dispatch("TillRoom::Till.Bump", id: "till-1") }.not_to raise_error
  end
end
