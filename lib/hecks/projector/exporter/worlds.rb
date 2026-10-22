require "json"

module Hecks
  module Projector
    module Exporter
      # The declared `.world` constructs as plain Hashes, in the shape `hecks-parse world
      # <file>...` prints as JSON, so the two parsers can be compared byte for byte. Only names are
      # exported: a bind's setting values (connection strings, keys) never leave the file, and the
      # default database is reported as a presence flag.
      module Worlds
        # Every world declared in a registry, one per domain, in first-declaration order.
        #
        # @param registry [Runtime::Registry] the registry the `.world` files were loaded into
        # @return [Array<Hash{String => Object}>] each world as `world_hash` builds it
        def worlds(registry)
          registry.worlds.values.map { |world| world_hash(world) }
        end

        # Exports one world with string keys in the fixed order domain, realm, latest,
        # default_adapter, default_database, bindings.
        #
        # @param world [Bluebook::World] the world to export
        # @return [Hash{String => Object}] `"domain"` (String); `"realm"`, `"latest"` and
        #   `"default_adapter"` (String, nil when unset or empty); `"default_database"` (true
        #   only when a non-empty connection is declared, never the connection itself);
        #   `"bindings"` (see `world_bindings`)
        def world_hash(world)
          {
            "domain"           => world.domain,
            "realm"            => present_string(world.realm),
            "latest"           => present_string(world.latest),
            "default_adapter"  => present_string(world.default_adapter),
            "default_database" => !present_string(world.default_database).nil?,
            "bindings"         => world_bindings(world)
          }
        end

        # The adapter binds of a world, from the qualified `"verb:adapter"` settings entries only
        # (the bare verb entry repeats the last of them), in the order they were declared.
        #
        # @param world [Bluebook::World] the world whose settings to read
        # @return [Array<Hash{String => Object}>] each `"verb"` (as written), `"adapter"` and
        #   `"settings"` (the setting names, never their values, in declaration order)
        def world_bindings(world)
          world.settings.filter_map do |key, value|
            next unless key.include?(":")

            adapter = value[:adapter].to_s
            { "verb" => key.delete_suffix(":#{adapter.downcase}"), "adapter" => adapter,
              "settings" => value.keys.reject { |name| name == :adapter }.map(&:to_s) }
          end
        end

        # Loads every given `.world` file, in order, into one fresh registry, so worlds of one
        # domain merge as they do at boot, and exports what it holds.
        #
        # @param paths [Array<String>] `.world` file paths
        # @return [Array<Hash{String => Object}>] `worlds` of that registry
        def worlds_in_files(paths)
          registry = Runtime::Registry.new
          Hecks.with_registry(registry) { paths.each { |path| Kernel.load(path) } }
          worlds(registry)
        end

        # The worlds of the given files as the pretty JSON `hecks-parse world` prints for them,
        # byte for byte: the bundled json's `JSON.pretty_generate`.
        #
        # @param paths [Array<String>] `.world` file paths
        # @return [String] the JSON `hecks-parse world` prints for the same files
        def worlds_json(paths)
          JSON.pretty_generate(worlds_in_files(paths))
        end

        # The IR's `world` key: what a domain's world says about persistence, names only. A missing
        # file, or a file with no world for the domain, gives the empty default.
        #
        # @param path [String] the `.world` file the domain sits beside (it need not exist)
        # @param domain [String] the target domain's name
        # @return [Hash{String => Object}] `"default_adapter"` (String or nil), `"default_database"`
        #   (Boolean) and `"persistence"` (each `persisted_by` bind as `"adapter"` and the
        #   `"settings"` names)
        def persistence_world(path, domain)
          world = (File.file?(path) ? worlds_in_files([path]) : []).find { |entry| entry["domain"] == domain }
          return { "default_adapter" => nil, "default_database" => false, "persistence" => [] } unless world

          { "default_adapter" => world["default_adapter"], "default_database" => world["default_database"],
            "persistence" => persisted_by_binds(world["bindings"]) }
        end

        # @param bindings [Array<Hash{String => Object}>] a world's `"bindings"`
        # @return [Array<Hash{String => Object}>] the `persisted_by` ones as adapter and setting names
        def persisted_by_binds(bindings)
          bindings.select { |bind| bind["verb"] == "persisted_by" }
                  .map { |bind| { "adapter" => bind["adapter"], "settings" => bind["settings"] } }
        end

        # @param value [String, nil] a scalar a world may leave unset
        # @return [String, nil] the value, or nil when it is nil or empty
        def present_string(value) = value.nil? || value.empty? ? nil : value
      end
    end
  end
end
