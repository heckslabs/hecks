# frozen_string_literal: true

module Hecks
  module Adapters
    class LocalRunner
      # What an adapter of the `LocalRunner` port answers with: each field in the shape
      # `Experiment::Complete` takes it, so the chapter's policy passes it on as it stands.
      module Answer
        module_function

        # @param asked [Hash{Symbol => Object}] the experiment's own fields, plain: `lever`,
        #   `base_ref` and `candidate_ref`
        # @param definition [String] the definition's name
        # @param verdict [Verdict] what the samples say
        # @param load [Float] the machine's one-minute load average when the experiment started
        # @param unmeasured [Array<String>] a note for each step left out of both sides
        # @return [Hash{Symbol => Hash}] the answer
        def build(asked:, definition:, verdict:, load:, unmeasured:)
          basis = verdict.basis(definition: definition, load: load,
                                refs: { base: asked[:base_ref], candidate: asked[:candidate_ref] })
          fields = timings(verdict).merge(load: load.round(2), unmeasured: unmeasured.join("; "),
                                          verdict: verdict.verdict, basis: basis,
                                          reestimates: asked[:lever].to_s,
                                          expected_seconds: verdict.expected_seconds)
          fields.transform_values { |value| wrap(value) }
        end

        # @param verdict [Verdict] what the samples say
        # @return [Hash{Symbol => Float}] each side's time, the spread and the saving
        def timings(verdict)
          { base_seconds: verdict.base_seconds, candidate_seconds: verdict.candidate_seconds,
            spread_seconds: verdict.spread_seconds, saved_seconds: verdict.saved_seconds }
        end

        # @param value [Object] a field's value
        # @return [Hash{Symbol => Object}] the value in the single-field shape commands take
        def wrap(value) = { value: value }
      end
    end
  end
end
