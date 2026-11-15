# frozen_string_literal: true

module Hecks
  module Adapters
    class CiRuns
      # The one-line record of a rerun of a CI run's failed jobs: the run and the pull request,
      # then the failed steps (each `job/step`) the failure named, when it named any.
      class RerunReport
        # @param run [String] the CI run that was rerun
        # @param pull [String] the pull request it belongs to
        # @param steps [String, nil] the failed steps, comma separated
        def initialize(run, pull, steps)
          @run = run
          @pull = pull
          @steps = steps.to_s.strip
        end

        # @return [String] the report
        def to_s
          text = "reran the failed jobs of CI run #{@run} (PR #{@pull})"
          @steps.empty? ? text : "#{text}; failed steps: #{@steps}"
        end
      end
    end
  end
end
