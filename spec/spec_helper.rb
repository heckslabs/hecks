# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "hecksagain"

# BOOTING WITHOUT TOUCHING DISK.
#
# The specs used to build a throwaway domain per example: mktmpdir, mkdir_p,
# copy the bluebook, write a hecksagon, delete the world, boot, remove the tree
# afterwards — six filesystem operations each, and a SQLite file besides. None
# of that is what they were testing.
#
# A bluebook needs no disk. `Hecks.boot` reads a DIRECTORY because that is the
# folder convention, but the loader underneath only composes declarations into
# a registry — so a spec can compose the same ones directly, bind Memory, and
# get the same door back.
#
# The bluebook itself stays a real FILE, and must: Prism reads a predicate's
# source to extract its canonical text, so a bluebook eval'd from a string has
# no source to read and every `given` would come back empty. Reading the real
# one is also the point — these specs test THAT bluebook, not a copy of it.
module InMemoryDomain
  ROOT             = File.expand_path("..", __dir__)
  PIZZAS_BLUEBOOK  = File.join(ROOT, "examples/pizzas/bluebook/pizzas.bluebook")
  PERSISTENCE_PORT = File.join(ROOT, "lib/hecksagain/ports/persistence/persistence.port")
  EXTRACTION_PORT  = File.join(ROOT, "lib/hecksagain/ports/extraction/extraction.port")
  MEMORY_ADAPTER   = File.join(ROOT, "lib/hecksagain/adapters/driven/memory/memory.adapter")
  PRISM_ADAPTER    = File.join(ROOT, "lib/hecksagain/adapters/driven/prism/prism.adapter")

  # A booted Pizzas domain held entirely in memory.
  #
  # Memory needs no configuration, so there is no world block — and a world
  # naming a field its adapter does not declare would be refused at boot, which
  # is the point of declaring fields on the adapter.
  def boot_in_memory
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      # Dependency order : ports declare the verb, an adapter declares a
      # port, the bluebook is read last. Extraction is loaded because
      # reading a `given` resolves that port — recovering a predicate's
      # source is an impure edge like any other, and an unbound one refuses
      # rather than silently returning empty text.
      Kernel.load(PERSISTENCE_PORT)
      Kernel.load(EXTRACTION_PORT)
      Kernel.load(MEMORY_ADAPTER)
      Kernel.load(PRISM_ADAPTER)
      Kernel.load(PIZZAS_BLUEBOOK)

      Hecks.hecksagon("Pizzas") { Pizzas::Pizza.persisted_by("Memory") }
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
