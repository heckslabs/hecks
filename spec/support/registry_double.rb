# frozen_string_literal: true

# A registry for a spec of something that reads one. It is a real, empty
# `Hecks::Runtime::Registry`, so every question the registry answers gets the answer an empty
# one gives (nil for a world or bluebook it does not hold, empty collections for the rest) and a
# setting row added to the reader later cannot fail the spec for lack of a stub. `answers` stub
# only what the example is about, and a later `allow(registry).to receive(:x).with(...)` for one of
# them falls back to that answer for any other argument.
module RegistryDouble
  # @param answers [Hash{Symbol => Object}] message names and what the registry answers to each
  # @return [Hecks::Runtime::Registry] an empty registry, with those messages answered
  def registry_double(**answers)
    registry = Hecks::Runtime::Registry.new
    allow(registry).to receive_messages({ binding_settings: {} }.merge(answers))
    registry
  end
end
