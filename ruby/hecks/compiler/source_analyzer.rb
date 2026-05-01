# Hecks::Compiler::SourceAnalyzer
#
# Orchestrates static analysis of Hecks Ruby source files using
# Prism AST (Layer 1) and Bluebook IR method-call resolution (Layer 2)
# to build a real dependency graph and topologically sort files into
# correct load order for the binary compiler.
#
#   files = SourceAnalyzer.analyze(lib_root: "lib")
#   files.each { |path| puts path }
#
require "prism"

module Hecks
  module Compiler
    module SourceAnalyzer
      # Analyzes all Ruby files under lib_root, builds a dependency
      # graph via Prism AST analysis and Bluebook IR consultation,
      # and returns files in load order.
      #
      # @param lib_root [String] path to the lib/ directory
      # @return [Array<String>] absolute file paths in load order
      def self.analyze(lib_root:, trace: false)
        lib_root = File.expand_path(lib_root)
        files = discover_files(lib_root)

        file_defs = {}
        file_refs = {}
        file_ns   = {}
        file_method_calls = {}
        file_mixin_refs = {}

        files.each do |path|
          source = File.read(path)
          defs = DefinitionExtractor.extract(source)
          refs = ReferenceExtractor.extract(source)

          file_defs[path] = defs.definitions
          file_refs[path] = refs.references
          file_ns[path]   = defs.namespaces
          file_method_calls[path] = refs.method_calls
          file_mixin_refs[path] = refs.mixin_refs
        end

        method_map = build_method_map(file_method_calls, files)
        wiring     = detect_wiring_files(files, lib_root)

        if trace
          wiring.each do |w|
            rel = w.sub("#{lib_root}/", "")
            $stderr.puts "[AUTOPHAGY] CLASSIFY #{rel} → WIRING"
          end
        end

        graph = DependencyGraph.new(
          file_defs, file_refs, file_ns,
          method_edges: method_map,
          wiring_files: wiring,
          mixin_refs: file_mixin_refs,
          trace: trace,
          lib_root: lib_root
        )
        sorted = graph.sorted_files
        apply_priority_ordering(sorted, lib_root, trace: trace)
      end

      # Ensures infrastructure files (errors, conventions, registries)
      # load before all other files.
      PRIORITY_PATTERNS = %w[
        /errors.rb
        /conventions
        /autoloads.rb
        /version.rb
        /registry.rb
        /set_registry.rb
        /module_dsl.rb
        /core_extensions.rb
        /registries/
        /naming_helpers.rb
        hecks/generator.rb
        hecks/dry_run_result.rb
      ].freeze

      def self.apply_priority_ordering(files, lib_root, trace: false)
        priority, rest = files.partition { |f|
          rel = f.sub("#{lib_root}/", "")
          PRIORITY_PATTERNS.any? { |pat| rel.include?(pat.delete_prefix("/")) }
        }
        if trace
          priority.each_with_index do |f, i|
            $stderr.puts "[AUTOPHAGY] PRIORITY ##{i} #{f.sub("#{lib_root}/", "")}"
          end
        end
        result = priority + rest
        if trace
          result.each_with_index do |f, i|
            $stderr.puts "[AUTOPHAGY] ORDER ##{i} #{f.sub("#{lib_root}/", "")}"
          end
        end
        result
      end

      # Discovers all Ruby source files under lib_root, excluding
      # templates, spec files, and generated output directories.
      #
      # @param lib_root [String] absolute path to lib/
      # @return [Array<String>] discovered file paths
      # External-dependency directories excluded from binary output.
      EXCLUDED_DIRS = %w[
        /templates/ /spec/ /examples/ /compiler/
        /hecks_cli/ /hecks_serve/ /hecks_mongodb/
        /hecks_ai/
      ].freeze

      def self.discover_files(lib_root)
        Dir.glob(File.join(lib_root, "**", "*.rb")).select { |f|
          EXCLUDED_DIRS.none? { |d| f.include?(d) } &&
          !excluded_file?(f)
        }.sort
      end

      # Checks if a file should be excluded from the binary: either it
      # inherits from an external gem or is a CLI command registration.
      EXTERNAL_SUPERCLASSES = /class\s+\w+\s*<\s*::?(Thor|Sinatra::Base|Rails::Railtie|Rails::Generators::Base)\b/
      CLI_REGISTRATION = /\AHecks::CLI\.register_command\b/

      def self.excluded_file?(path)
        File.foreach(path).any? { |line|
          line.match?(EXTERNAL_SUPERCLASSES) || line.match?(CLI_REGISTRATION)
        }
      rescue
        false
      end

      # Layer 2: Bluebook IR consultation.
      # Maps Hecks.method_name calls to the registry files that define them.
      # Scans file_method_calls to build edges from callers to registries.
      #
      # @return [Hash{String => String}] caller_file => depended_file
      def self.build_method_map(file_method_calls, files)
        registry_methods = build_registry_method_index(files)
        edges = {}

        file_method_calls.each do |file, methods|
          methods.each do |method_name|
            provider = registry_methods[method_name]
            next unless provider && provider != file
            edges[file] ||= []
            edges[file] << provider
          end
        end

        edges
      end

      # Builds an index of method_name => file for registry methods.
      # Registry files define methods that get extended onto Hecks.
      #
      # @return [Hash{String => String}] method_name => file_path
      def self.build_registry_method_index(files)
        index = {}
        registry_files = files.select { |f| f.include?("/registries/") }

        registry_files.each do |path|
          source = File.read(path)
          tree = Prism.parse(source).value
          extract_defined_methods(tree, index, path)
        end

        index
      end

      # Walk AST to find method definitions (def self.xxx or def xxx)
      def self.extract_defined_methods(node, index, path)
        if node.is_a?(Prism::DefNode)
          index[node.name.to_s] = path
        end
        node.child_nodes.compact.each do |child|
          extract_defined_methods(child, index, path)
        end
      end

      # Detects wiring files: foo.rb that has a corresponding foo/ directory
      # AND contains extend/include referencing constants from foo/.
      # These must load after all their children.
      #
      # @return [Set<String>] paths of wiring files
      def self.detect_wiring_files(files, lib_root)
        wiring = Set.new
        files.each do |path|
          dir = path.sub(/\.rb$/, "")
          next unless File.directory?(dir)
          source = File.read(path)
          if source.match?(/\b(extend|include|prepend)\b/)
            wiring << path
          end
        end
        wiring
      end

      private_class_method :apply_priority_ordering, :discover_files,
                           :excluded_file?,
                           :build_method_map, :build_registry_method_index,
                           :extract_defined_methods, :detect_wiring_files
    end
  end
end
