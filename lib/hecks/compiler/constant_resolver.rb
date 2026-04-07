# Hecks::Compiler::ConstantResolver
#
# Builds an index of Ruby constant definitions across files and
# resolves constant references to their defining file. Handles
# fully-qualified paths, suffix matching, and namespace-aware
# resolution for bare references inside enclosing scopes.
#
#   resolver = ConstantResolver.new(file_definitions, file_namespaces)
#   resolver.resolve("Hecks::DSL::DomainBuilder")
#     # => "/path/to/lib/hecks/dsl/domain_builder.rb"
#
module Hecks
  module Compiler
    class ConstantResolver
      def initialize(file_definitions, file_namespaces)
        @file_definitions = file_definitions
        @file_namespaces  = file_namespaces
        @index = build_index
      end

      # Resolves a constant reference to the file that defines it.
      # Tries full path first, then progressively shorter prefixes.
      #
      # @param ref [String] constant path (e.g. "Hecks::DSL::DomainBuilder")
      # @param exclude [String, nil] file to exclude from results
      # @return [String, nil] file path or nil
      def resolve(ref, exclude: nil)
        parts = ref.split("::")
        parts.length.downto(1) do |n|
          candidate = parts[0...n].join("::")
          provider = @index[candidate]
          return provider if provider && provider != exclude
        end
        nil
      end

      # Qualifies a reference with enclosing namespaces and resolves.
      #
      # @param ref [String] bare or partial constant name
      # @param scopes [Set<String>] enclosing namespace paths
      # @param exclude [String, nil] file to exclude
      # @return [String, nil] file path or nil
      def resolve_in_scope(ref, scopes, exclude: nil)
        scopes.each do |ns|
          provider = @index["#{ns}::#{ref}"]
          return provider if provider && provider != exclude
        end
        nil
      end

      # Checks if a bare reference matches any locally defined constant.
      # E.g., "DomainVisualizer" matches "Hecks::DomainVisualizer".
      def defined_locally?(ref, scopes)
        suffix = "::#{ref}"
        scopes.any? { |s| s == ref || s.end_with?(suffix) }
      end

      private

      def build_index
        all_namespaces = @file_namespaces.values.flatten.to_set
        index = {}

        @file_definitions.each do |file, constants|
          constants.each do |const|
            next if all_namespaces.include?(const)
            index[const] = file unless index.key?(const)
          end
        end

        @file_namespaces.each do |file, namespaces|
          namespaces.each do |ns|
            index[ns] = file unless index.key?(ns)
          end
        end

        build_suffix_entries(index, all_namespaces)
        index
      end

      # Suffix-derived entries for qualified refs (3+ segments).
      # Avoids false edges from bare names like "Names" or "Utils".
      def build_suffix_entries(index, all_namespaces)
        @file_definitions.each do |file, constants|
          constants.each do |const|
            next if all_namespaces.include?(const)
            parts = const.split("::")
            next if parts.length < 3
            (1...parts.length).each do |i|
              suffix = parts[i..].join("::")
              next if suffix.split("::").length < 2
              index[suffix] = file unless index.key?(suffix)
            end
          end
        end
      end
    end
  end
end
