# Hecks::Compiler::DependencyGraph
#
# Builds a file-level dependency graph from definition and reference
# data, then topologically sorts it using Kahn's algorithm. Handles
# cycles via CycleSorter. Wiring files (foo.rb with foo/ directory)
# are forced to load after their children.
#
#   graph = DependencyGraph.new(file_defs, file_refs, file_ns,
#     method_edges: {}, wiring_files: Set.new)
#   graph.sorted_files  # => ["/path/to/a.rb", "/path/to/b.rb"]
#
module Hecks
  module Compiler
    class DependencyGraph
      def initialize(file_definitions, file_references, file_namespaces = {},
                     method_edges: {}, wiring_files: Set.new,
                     mixin_refs: {}, trace: false, lib_root: "")
        @file_definitions = file_definitions
        @file_references  = file_references
        @file_namespaces  = file_namespaces
        @method_edges     = method_edges
        @wiring_files     = wiring_files
        @mixin_refs       = mixin_refs
        @files            = file_definitions.keys
        @trace            = trace
        @lib_root         = lib_root
        @resolver = ConstantResolver.new(file_definitions, file_namespaces)
      end

      # Returns files in topological order (dependencies first).
      #
      # @return [Array<String>] sorted file paths
      def sorted_files
        edges = build_edges
        inject_method_edges(edges)
        inject_wiring_edges(edges)
        kahn_sort(edges)
      end

      private

      def build_edges
        edges = Hash.new { |h, k| h[k] = Set.new }
        @files.each { |f| edges[f] }

        @file_references.each do |file, refs|
          own_namespaces = (@file_namespaces[file] || []).to_set
          own_defs = (@file_definitions[file] || []).to_set
          scopes = own_namespaces | own_defs

          refs.each do |ref|
            next if own_namespaces.include?(ref) || own_defs.include?(ref)
            next if @resolver.defined_locally?(ref, scopes)
            provider = @resolver.resolve(ref, exclude: file)
            provider ||= @resolver.resolve_in_scope(ref, scopes, exclude: file)
            next unless provider
            trace_edge(file, provider, "ref: #{ref}") if @trace
            edges[file] << provider
          end
        end

        inject_mixin_edges(edges)
        edges
      end

      # Resolves bare mixin refs (include Foo) using enclosing scopes.
      def inject_mixin_edges(edges)
        @mixin_refs.each do |file, mixins|
          scopes = ((@file_namespaces[file] || []) + (@file_definitions[file] || [])).to_set
          mixins.each do |ref|
            next if ref.include?("::")
            next if @resolver.resolve(ref, exclude: file)
            provider = @resolver.resolve_in_scope(ref, scopes, exclude: file)
            next unless provider
            trace_edge(file, provider, "mixin-ns") if @trace
            edges[file] << provider
          end
        end
      end

      def inject_method_edges(edges)
        @method_edges.each do |caller_file, deps|
          deps.each do |dep|
            next if dep == caller_file
            trace_edge(caller_file, dep, "method") if @trace
            (edges[caller_file] ||= Set.new) << dep
          end
        end
      end

      # Wiring files depend on all files in their corresponding directory.
      def inject_wiring_edges(edges)
        @wiring_files.each do |wiring_file|
          dir = wiring_file.sub(/\.rb$/, "")
          @files.select { |f| f.start_with?("#{dir}/") }.each do |child|
            trace_edge(wiring_file, child, "wiring") if @trace
            (edges[wiring_file] ||= Set.new) << child
          end
        end
      end

      def kahn_sort(edges)
        in_degree = {}
        edges.each_key { |f| in_degree[f] = edges[f].size }
        edges.each_value { |deps| deps.each { |d| in_degree[d] ||= 0 } }

        queue = in_degree.select { |_, d| d == 0 }.keys.sort
        result = []
        removed = Set.new

        while queue.any?
          file = queue.shift
          result << file
          removed << file
          edges.each do |dependent, deps|
            next if removed.include?(dependent) || !deps.include?(file)
            in_degree[dependent] -= 1
            queue.push(dependent).sort! if in_degree[dependent] == 0
          end
        end

        remaining = @files - result
        ordered = CycleSorter.new(remaining, edges, wiring_files: @wiring_files).sorted
        trace_cycle(remaining) if @trace && remaining.any?
        result + ordered
      end

      def rel(path)
        path.sub("#{@lib_root}/", "")
      end

      def trace_edge(from, to, kind)
        $stderr.puts "[AUTOPHAGY] EDGE #{rel(from)} → #{rel(to)} (#{kind})"
      end

      def trace_cycle(remaining)
        $stderr.puts "[AUTOPHAGY] CYCLE: #{remaining.map { |f| rel(f) }.join(', ')}"
      end
    end
  end
end
