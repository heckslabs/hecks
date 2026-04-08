module ModelRegistryDomain
  module Workflows
    class ModelApproval
      unless defined?(STEPS)
        STEPS = [
          { command: "SubmitAssessment" },
          { command: "#<Hecks::BluebookModel::Behavior::BranchStep:0x000000011c45ae30>" },
        ].freeze
      end

      attr_reader :results

      def call(**attrs)
        @results = []
        # Execute steps in sequence, evaluate branches
        self
      end
    end
  end
end
