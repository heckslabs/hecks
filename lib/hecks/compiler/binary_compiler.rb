# Hecks::Compiler::BinaryCompiler
#
# Orchestrates compilation of the Hecks framework into a single
# self-contained Ruby script. Uses SourceAnalyzer for Prism-based
# dependency resolution and topological file ordering.
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
        @lib_root = lib_root || default_lib_root
      end

      # Compiles all Hecks source into a bundled executable using
      # static analysis for file ordering (no runtime introspection).
      #
      # @param output [String] output file path (default: "hecks_v0")
      # @return [String] absolute path to the compiled binary
      def compile(output: "hecks_v0", trace: false)
        files = SourceAnalyzer.analyze(lib_root: lib_root, trace: trace)

        if files.empty?
          raise "No Hecks source files found under #{lib_root}."
        end

        output_path = File.expand_path(output)
        BundleWriter.write(files, output: output_path, lib_root: lib_root)
        output_path
      end

      # Reports what would be compiled without writing anything.
      #
      # @return [Hash] compilation plan with file count and paths
      def plan
        files = SourceAnalyzer.analyze(lib_root: lib_root)
        {
          lib_root: lib_root,
          file_count: files.size,
          files: files.map { |f| f.sub("#{lib_root}/", "") }
        }
      end

      private

      def default_lib_root
        File.expand_path("../..", __dir__)
      end
    end
  end
end
