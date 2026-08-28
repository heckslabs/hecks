require "hecks"
require_relative "../../fixtures/broken_clock"

# The finding: a `.port` file's `verb`/`signal` never carried the one
# fact a live dispatch actually depends on — the method an adapter must
# respond to. `Port#answers` (port_builder.rb) declares it; `verify!`'s
# own `check_answers`/`verify_singleton_port_answers!` (registry/
# verification.rb) is what turns a bare `NoMethodError`, discovered live
# on the FIRST real dispatch that needed the time, into a `WiringError`
# a boot refuses to start with — the same shape `check_settings` already
# gives a `.world` field the adapter never declared.
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

  it "leaves the existing zero/many refusal alone — that stays a live, first-dispatch check, not a boot one" do
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
