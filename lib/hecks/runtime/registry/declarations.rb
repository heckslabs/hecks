module Hecks
  module Runtime
    class Registry
      # What a boot gathers while the `.bluebook`, `.hecksagon`, `.world` and `.contextmap` files
      # load: the bluebooks and their builders, the wiring, ports, adapters, worlds, translations,
      # context maps, the eras the boot gate resolved, and the privacy markings still to be
      # dispatched.
      Declarations = Struct.new(:bluebooks, :bluebook_sources, :hecksagons, :bounded_bluebooks, :ports,
                                :adapters, :worlds, :translations, :bluebook_builders,
                                :pending_privacy_markings, :resolved_eras, :superseded_eras,
                                :context_maps) do
        # @return [Declarations] every collection empty
        def self.empty
          new({}, {}, {}, {}, {}, {}, {}, [], {}, [], {}, {}, {})
        end

        # Stores a value under a key in a keyed collection, and answers the value.
        #
        # @param collection [Symbol] the member holding the keyed collection
        # @param key [Object] the key
        # @param value [Object] the value to store
        # @return [Object] `value`
        def store(collection, key, value) = self[collection][key] = value

        # Removes a key from a keyed collection.
        #
        # @param collection [Symbol] the member holding the keyed collection
        # @param key [Object] the key to remove
        # @return [Object, nil] the value removed, or nil when the key was absent
        def remove(collection, key) = self[collection].delete(key)

        # Appends a value to a list collection.
        #
        # @param collection [Symbol] the member holding the list
        # @param value [Object] the value to append
        # @return [Array] the list, `value` last
        def append(collection, value) = self[collection] << value

        # Records that a `.bluebook` file contributed to a bluebook name.
        #
        # @param name [String] the bluebook name
        # @param path [String] the file that declared it
        # @return [Array<String>] every path recorded for that name, `path` last
        def record_source(name, path) = (bluebook_sources[name] ||= []) << path
      end
    end
  end
end
