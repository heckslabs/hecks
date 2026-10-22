require "json"

module Hecks
  module Projector
    module Exporter
      # The declared `.adapter` constructs as plain Hashes, in the shape
      # `hecks-parse adapter <file>...` prints as JSON, so the two parsers can be compared byte
      # for byte.
      module Adapters
        # Every adapter declared in a registry, in declaration order.
        #
        # @param registry [Runtime::Registry] the registry the `.adapter` files were loaded into
        # @return [Array<Hash{String => Object}>] each adapter as `adapter_hash` builds it
        def adapters(registry)
          registry.adapters.values.map { |adapter| adapter_hash(adapter) }
        end

        # Exports one adapter with string keys in the fixed order name, port, fields, secrets,
        # defaults.
        #
        # @param adapter [Bluebook::Hecksagon::Adapter] the adapter to export
        # @return [Hash{String => Object}] `"name"` (String), `"port"` (String, nil when never
        #   declared), `"fields"`/`"secrets"` (`Array<String>`), `"defaults"` (field name to its
        #   JSON-native default, in first-declaration order)
        def adapter_hash(adapter)
          {
            "name"     => adapter.name,
            "port"     => adapter.port,
            "fields"   => (adapter.fields || []).map(&:to_s),
            "secrets"  => (adapter.secrets || []).map(&:to_s),
            "defaults" => adapter.declared_defaults.to_h { |field, value| [field.to_s, value] }
          }
        end

        # Loads each `.adapter` file into its own fresh registry and exports what it declared,
        # in file order then declaration order.
        #
        # @param paths [Array<String>] `.adapter` file paths
        # @return [Array<Hash{String => Object}>] `adapters` of each loaded registry, concatenated
        def adapters_in_files(paths)
          paths.flat_map { |path| adapters(load_adapter_file(path)) }
        end

        # The adapters of the given files as the pretty JSON `hecks-parse adapter` prints for them,
        # byte for byte: the bundled json's `JSON.pretty_generate`, whose spacing of an empty
        # collection `hecks-parse` reproduces.
        #
        # @param paths [Array<String>] `.adapter` file paths
        # @return [String] the JSON `hecks-parse adapter` prints for the same files
        def adapters_json(paths)
          JSON.pretty_generate(adapters_in_files(paths))
        end

        # Loads one `.adapter` file into a fresh registry. The file's own `require "hecks/..."`
        # line loads the implementing class and needs `lib/` on the load path, as it is under
        # bundler.
        #
        # @param path [String] an `.adapter` file path
        # @return [Runtime::Registry] a registry holding only that file's adapters
        def load_adapter_file(path)
          registry = Runtime::Registry.new
          Hecks.with_registry(registry) { Kernel.load(path) }
          registry
        end
      end
    end
  end
end
