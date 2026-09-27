module Hecks
  module Fuzzing
    # Names the construct family behind each query verb the Ruby/Rust comparison skipped.
    # The construct is read from the binary's manifest entry, not guessed from the declaration.
    module StructuralSkips
      module_function

      # Attributes each skipped verb to the construct family its manifest entry names.
      # A verb the manifest does not declare answers `unknown`, which no boundary admits.
      #
      # @param gaps [Fuzzing::RustGapManifest] the binary's not-generated manifest entries
      # @param verbs [Array<String>] the skipped query/read-model verbs to attribute
      # @return [Array<Hash{Symbol => Object}>] one `{ verb:, constructs: }` per verb,
      #   sorted by verb
      def attribute(gaps, verbs)
        verbs.sort.map do |verb|
          entry = gaps.not_generated(verb)
          { verb: verb, constructs: entry ? [entry.fetch("construct")] : %w[unknown] }
        end
      end

      # Selects the attributed entries whose constructs are not all inside `boundary`.
      #
      # @param attributed [Array<Hash{Symbol => Object}>] entries as returned by `attribute`
      # @param boundary [Array<String, Symbol>] the construct families the codegen boundary admits
      # @return [Array<Hash{Symbol => Object}>] the entries naming an unadmitted construct
      def outside_boundary(attributed, boundary)
        admitted = boundary.map(&:to_s)
        attributed.select { |entry| entry[:constructs].empty? || (entry[:constructs] - admitted).any? }
      end
    end
  end
end
