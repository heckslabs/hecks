# frozen_string_literal: true

require "hecks/runtime/dispatcher"
require "hecks/runtime/errors"

module Hecks
  module Adapters
    class MainIntegration
      # What an advance does with a step that raised instead of answering or being refused. An ask
      # turns the outside world's failures into refusals, but a defect in the code
      # (`Runtime.programming_error?`) is raised past it, after the step has moved its run into
      # verifying or boarding; the reaction that met it is settled as a defect, so the run would
      # wait there with no reason. The step's own record then takes the defect's text through
      # `Fail` or `Reject`, so the saga parks the run in needs_human with a reason a person can
      # read. An `Observe` that raised records nothing: CI did not fail, and the next advance
      # reads the run again.
      class Fault
        # The command that records a raised step, by the step that raised.
        RECORDERS = { "Verify" => "Fail", "Board" => "Reject" }.freeze

        # @param defect [Hash] one row of a dispatch's `reaction_defects`
        # @return [String] the defect as one line: its error class and reason
        def self.text_of(defect)
          reason = defect[:reason].to_s
          klass = defect[:error_class].to_s
          klass.empty? || reason.start_with?(klass) ? reason : "#{klass}: #{reason}"
        end

        # @param registry [Runtime::Registry] the booted registry the record is dispatched through
        def initialize(registry)
          @registry = registry
        end

        # Records that one run's step raised, when its step has a recorder.
        #
        # @param run [Runs::Run] the run whose step raised
        # @param command [String] the step's command: `Verify`, `Board` or `Observe`
        # @param key [String, nil] the step's `Integration` record, or nil when none was made
        # @param error [String] what the step raised: the error's class and message
        # @return [String] the advance's line for the run: what raised, and how it was recorded
        def record(run, command, key, error)
          text = "#{command} raised #{error}"
          line = "#{run.short} #{run.state} -> #{text}"
          recorder = RECORDERS[command]
          return line unless recorder && key

          "#{line}; #{park(recorder, key, run, text)}"
        end

        private

        def park(recorder, key, run, text)
          arguments = { to: key, landed: run.landed, refusal: text }
          Runtime::Dispatcher.new(@registry).dispatch_flat("Hecks::Integration.#{recorder}", arguments)
          "recorded by #{recorder}"
        rescue *Runtime::DOMAIN_REFUSALS, StandardError => e
          "#{recorder} refused: #{e.message}"
        end
      end
    end
  end
end
