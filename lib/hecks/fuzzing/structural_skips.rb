module Hecks
  module Fuzzing
    # What each query verb the differential comparison skipped was hiding.
    #
    # `Differential.manifest_partition` drops a named query or read model
    # from both sides of the Ruby/Rust comparison only when the binary's own
    # manifest.json declares it `generated: false`. The drop is correct, but
    # a sweep that dropped every `offset`/`cursor` ask would still read as
    # "agreed across all steps". `bin/qa_sweep` therefore logs one Check per
    # sweep naming every skipped verb and the construct family that caused
    # it, and marks it Surprised when a family is outside
    # `QualityControlDials::STRUCTURAL_REFUSAL_BOUNDARY`.
    #
    # The construct comes straight from the manifest entry, written by the
    # generator branch that made the skip (`Projector::SkipReason`), rather
    # than guessed from the Ruby declaration's `to_h` keys, which is coarser
    # than codegen's own decision and can drift from it.
    module StructuralSkips
      module_function

      # Attributes each skipped verb to the construct family its manifest
      # entry names.
      #
      # One entry per skipped verb: `{ verb:, constructs: [...] }`, sorted by
      # verb so the printed observation is stable across seeds and runs. A
      # verb the manifest doesn't declare answers `unknown`, which no
      # boundary admits.
      #
      # @param gaps [Fuzzing::RustGapManifest] the binary's not-generated manifest entries
      # @param verbs [Array<String>] the skipped query/read-model verbs to attribute
      # @return [Array<Hash{Symbol => Object}>] one `{ verb: String, constructs: Array<String> }`
      #   per verb, in sorted-verb order
      def attribute(gaps, verbs)
        verbs.sort.map do |verb|
          entry = gaps.not_generated(verb)
          { verb: verb, constructs: entry ? [entry.fetch("construct")] : %w[unknown] }
        end
      end

      # Selects the attributed entries whose constructs are not all inside `boundary`.
      #
      # @param attributed [Array<Hash{Symbol => Object}>] entries as returned by `attribute`
      # @param boundary [Array<String, Symbol>] the construct families the documented codegen
      #   boundary admits
      # @return [Array<Hash{Symbol => Object}>] the subset of `attributed` naming an
      #   unadmitted construct, or no construct at all
      def outside_boundary(attributed, boundary)
        admitted = boundary.map(&:to_s)
        attributed.select { |entry| entry[:constructs].empty? || (entry[:constructs] - admitted).any? }
      end
    end
  end
end
