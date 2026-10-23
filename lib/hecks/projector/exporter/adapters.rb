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
          declared = {
            "name"     => adapter.name,
            "port"     => adapter.port,
            "fields"   => (adapter.fields || []).map(&:to_s),
            "secrets"  => (adapter.secrets || []).map(&:to_s),
            "defaults" => adapter.declared_defaults.to_h { |field, value| [field.to_s, value] }
          }
          return declared unless adapter.plugin?

          declared.merge("answers" => adapter.answered_queries, "runs" => adapter.runs)
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

        # Directories that hold copies or build output, never a source `.adapter`; the Rust
        # builder skips the same names (and any dot-directory).
        SKIPPED_DIRS = %w[target vendor node_modules tmp .git].freeze

        # Every `.adapter` file under the given directories, for the IR's `adapters` key. The
        # Rust builder scans the same directories the same way.
        #
        # @param directories [Array<String>] directories to scan recursively
        # @return [Array<String>] absolute paths, unique and in byte order, none beneath a
        #   skipped or hidden directory (relative to the directory scanned)
        def adapter_files_under(directories)
          directories.flat_map do |directory|
            base = File.expand_path(directory)
            Dir.glob(File.join(base, "**", "*.adapter")).reject do |path|
              path.delete_prefix("#{base}/").split("/")[0...-1].any? { |part| SKIPPED_DIRS.include?(part) }
            end
          end.uniq.sort_by(&:b)
        end

        # The declarations of the adapters a domain binds, the IR's `adapters` key: one entry
        # per distinct bound name that some `.adapter` file declares, in name byte order. Only
        # declarations: never a world's setting values. A bound name nothing declares is
        # omitted, for the host to refuse. Of two files declaring one name, the first path wins.
        # A file is loaded only if it quotes a bound name, which cannot change the result.
        #
        # @param persistence [Hash{Symbol => Object}] `persistence`'s `:aggregates` with `:adapter`
        # @param paths [Array<String>] candidate `.adapter` files, in precedence order
        # @return [Array<Hash{String => Object}>] each as `adapter_hash` builds it
        def persistence_adapters(persistence, paths)
          wanted = bound_adapter_names(persistence)
          declared = adapters_in_files(paths.select { |path| quotes_any?(File.read(path), wanted) })
          declared.select { |adapter| wanted.include?(adapter["name"]) }.uniq { |a| a["name"] }
                  .sort_by { |adapter| adapter["name"].b }
        end

        # @param persistence [Hash{Symbol => Object}] `persistence`'s result
        # @return [Array<String>] the distinct adapter names its aggregates bind
        def bound_adapter_names(persistence) = persistence.fetch(:aggregates).map { |row| row.fetch(:adapter) }.uniq

        # @param text [String] a file's text
        # @param names [Array<String>] adapter names
        # @return [Boolean] whether the text quotes any of the names
        def quotes_any?(text, names) = names.any? { |name| text.include?("\"#{name}\"") }

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
