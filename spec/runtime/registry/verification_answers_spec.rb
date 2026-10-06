require "hecks"
require_relative "../../fixtures/broken_clock"

# `verify!` turns a missing `Port#answers` method on an adapter into a boot-time `WiringError`
# instead of a `NoMethodError` on the first live dispatch.
RSpec.describe "Port#answers, checked at verify!" do
  CLOCK_PORT       = File.expand_path("../../../lib/hecks/ports/clock.port", __dir__)
  SYSTEM_CLOCK     = File.expand_path("../../../lib/hecks/adapters/driven/system_clock.adapter", __dir__)
  BROKEN_CLOCK     = File.expand_path("../../fixtures/broken_clock.adapter", __dir__)

  def registry_with(*adapter_paths)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(CLOCK_PORT)
      adapter_paths.each { |path| Kernel.load(path) }
    end
    registry
  end

  it "refuses to boot a singleton adapter that does not respond to what its port declares" do
    registry = registry_with(BROKEN_CLOCK)

    expect { registry.verify! }
      .to raise_error(Hecks::Runtime::WiringError, /BrokenClock.*does not respond to.*:now/)
  end

  it "boots clean when the one bound adapter answers everything its port declares" do
    registry = registry_with(SYSTEM_CLOCK)

    expect { registry.verify! }.not_to raise_error
  end

  it "leaves the existing zero/many refusal alone — that stays a live, first-dispatch check, not a boot one",
     :aggregate_failures do
    empty_registry = registry_with
    expect { empty_registry.verify! }.not_to raise_error
    expect { Hecks::Ports::Clock.now(empty_registry) }
      .to raise_error(Hecks::Runtime::WiringError, /no adapter implements/)
  end

  it "routes the singleton port's own resolution through adapter_class, not a bare const_get" do
    registry = registry_with(SYSTEM_CLOCK)
    expect(Hecks::Ports::Clock.adapter(registry)).to eq(Hecks::Adapters::SystemClock)
  end
end
