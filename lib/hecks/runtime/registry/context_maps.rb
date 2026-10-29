module Hecks
  module Runtime
    class Registry
      # The context maps a boot loaded from `.contextmap` files, one per system.
      module ContextMaps
        # Boot-time-only, single-threaded: it runs from Hecks.collect while a `.contextmap` file is
        # being Kernel.loaded, before the registry reaches a live, multi-threaded caller.
        # Registers a declared context map under its system's name, a later one of the same name
        # replacing the earlier (a map is one declaration, not a layered overlay).
        #
        # @param item [Bluebook::ContextMap] the declared map
        # @return [Bluebook::ContextMap] the map
        def add_context_map(item) = @declared.store(:context_maps, item.name, item)

        # Finds a system's declared context map by name.
        #
        # @param name [String, Symbol] the system the map covers
        # @return [Bluebook::ContextMap, nil] the map, or nil if none is registered under `name`
        def context_map(name) = @declared.context_maps[name.to_s]

        # @return [Array<Bluebook::ContextMap>] every declared context map
        def context_maps = @declared.context_maps.values
      end
    end
  end
end
