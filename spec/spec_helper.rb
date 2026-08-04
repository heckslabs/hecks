
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

if ENV["COVERAGE"]
  require "simplecov"
  SimpleCov.start do
    enable_coverage :branch
    add_filter "/spec/"
  end
end

require "hecksagain"

module InMemoryDomain
  ROOT             = File.expand_path("..", __dir__)
  PIZZAS_BLUEBOOK  = File.join(ROOT, "examples/pizzas/bluebook/pizzas.bluebook")
  PERSISTENCE_PORT = File.join(ROOT, "lib/hecksagain/ports/persistence.port")
  EXTRACTION_PORT  = File.join(ROOT, "lib/hecksagain/ports/extraction.port")
  MEMORY_ADAPTER   = File.join(ROOT, "lib/hecksagain/adapters/driven/memory.adapter")
  PRISM_ADAPTER    = File.join(ROOT, "lib/hecksagain/adapters/driven/prism.adapter")

  def boot_in_memory
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(PERSISTENCE_PORT)
      Kernel.load(EXTRACTION_PORT)
      Kernel.load(MEMORY_ADAPTER)
      Kernel.load(PRISM_ADAPTER)
      Kernel.load(PIZZAS_BLUEBOOK)

      # `::` on purpose — a real .hecksagon file is loaded at TOP LEVEL, where an
      # unresolved constant reaches Object's const_missing (ConstShim ->
      # BindingProxy). This block lives inside a module, so a bare `Pizzas`
      # would be looked up here first and reach no hook at all.
      Hecks.hecksagon("Pizzas") { ::Pizzas::Order.persisted_by("Memory") }
    end

    registry.verify!
    Hecksagain::Runtime::Loader.bind_runtime(
      Hecksagain::Runtime::Dispatcher.new(registry)
    )
  end
end

RSpec.configure do |config|
  config.include InMemoryDomain

  config.expect_with(:rspec) { |expectations| expectations.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
end
