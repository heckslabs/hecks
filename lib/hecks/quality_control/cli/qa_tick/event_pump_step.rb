# frozen_string_literal: true

require_relative "../qa_event_pump"
require_relative "push_nudge_step"
require_relative "train_watch_step"

module Hecks
  module QualityControlCli
    class QaTick
      # The tick's last finding step: the event pump, which runs each attached domain's policies
      # on the events its cursors have not yet read.
      module EventPumpStep
        include PushNudgeStep
        include TrainWatchStep

        private

        # @return [Array<Step>] the steps after the finding steps: the push check, the pump, and the
        #   train watch
        def watch_steps = push_nudge_steps + pump_steps + train_watch_steps

        # @return [Array<Step>] the pump's step when the `event_pump` dial is on, else none
        def pump_steps
          dial(:EVENT_PUMP, false) ? [guarded("event_pump") { run_event_pump }] : []
        end

        # @return [Array(String, Integer)] the pump's output and its exit status
        def run_event_pump
          banner "hecks quality_control event_pump.pump!"
          output, exit_code = run_step(->(argv) { QaEventPump.call(argv, root: @root) })
          puts output
          [output, exit_code]
        end
      end
    end
  end
end
