module Hecks
  module Fuzzing
    # WHAT EACH QUERY VERB THE DIFFERENTIAL COMPARISON SKIPPED WAS HIDING.
    #
    # `Differential.manifest_partition` drops a named query or read model
    # from BOTH sides of the Ruby/Rust comparison only when the binary's own
    # manifest.json declares it `generated: false`. The drop is correct, but
    # a sweep that dropped every `offset`/`cursor` ask would still read as
    # "agreed across all steps". `bin/qa_sweep` therefore logs one Check per
    # sweep naming every skipped verb and the construct family that caused
    # it, and marks it Surprised when a family is outside
    # `QualityControlDials::STRUCTURAL_REFUSAL_BOUNDARY`.
    #
    # The construct comes straight from the manifest entry, written by the
    # generator branch that made the skip (`Projector::SkipReason`). This
    # module used to guess it from the Ruby declaration's `to_h` keys, which
    # was coarser than codegen's own decision and could drift from it.
    module StructuralSkips
      module_function

      # One entry per skipped verb: `{ verb:, constructs: [...] }`, sorted by
      # verb so the printed observation is stable across seeds and runs. A
      # verb the manifest doesn't declare answers `unknown`, which no
      # boundary admits.
      def attribute(gaps, verbs)
        verbs.sort.map do |verb|
          entry = gaps.not_generated(verb)
          { verb: verb, constructs: entry ? [entry.fetch("construct")] : %w[unknown] }
        end
      end

      # Every skipped verb whose constructs are NOT all inside `boundary`.
      def outside_boundary(attributed, boundary)
        admitted = boundary.map(&:to_s)
        attributed.select { |entry| entry[:constructs].empty? || (entry[:constructs] - admitted).any? }
      end
    end
  end
end
