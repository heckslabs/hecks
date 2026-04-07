# Hecks::Compiler::BinaryCompiler
#
# Orchestrates compilation of the Hecks framework into a single
# self-contained Ruby script. Collects all loaded source files,
# concatenates them in load order, and writes a bundled executable.
#
#   compiler = Hecks::Compiler::BinaryCompiler.new
#   compiler.compile(output: "hecks_v0")
#
module Hecks
  module Compiler
    class BinaryCompiler
      attr_reader :lib_root

      # @param lib_root [String] path to the lib/ directory
      def initialize(lib_root: nil)
        @lib_root = lib_root || SourceCollector.default_lib_root
      end

      # Compiles all loaded Hecks source into a bundled executable.
      #
      # @param output [String] output file path (default: "hecks_v0")
      # @return [String] absolute path to the compiled binary
      def compile(output: "hecks_v0")
        files = SourceCollector.collect(lib_root: lib_root)

        if files.empty?
          raise "No Hecks source files found under #{lib_root}. " \
                "Is Hecks loaded? (require 'hecks' first)"
        end

        output_path = File.expand_path(output)
        BundleWriter.write(files, output: output_path, lib_root: lib_root)
        output_path
      end

      # Reports what would be compiled without writing anything.
      #
      # @return [Hash] compilation plan with file count and paths
      def plan
        files = SourceCollector.collect(lib_root: lib_root)
        {
          lib_root: lib_root,
          file_count: files.size,
          files: files.map { |f| f.sub("#{lib_root}/", "") }
        }
      end
    end
  end
end
