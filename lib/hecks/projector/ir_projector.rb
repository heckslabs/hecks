module Hecks
  module Projector
    # Projects a bluebook as its own canonical IR, via `Bluebook#to_h`.
    # Needs no live runtime, and the output is deterministic.
    module IRProjector
      module_function

      # Projects `bluebook` as its own canonical IR.
      #
      # @param bluebook [Hecks::IR] the IR-emitting construct to project
      # @param options [Hash] unused; accepted to satisfy the registry's call shape
      # @return [Hash] `bluebook`'s canonical IR, as built by `Hecks::IR::Emits#to_h`
      # @raise [Hecks::IR::Undeclared] if `bluebook` never declared its shape with `emits_ir`
      def call(bluebook:, options: {}) = bluebook.to_h
    end
  end
end
