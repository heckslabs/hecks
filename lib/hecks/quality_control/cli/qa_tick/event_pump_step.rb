# frozen_string_literal: true

require_relative "../qa_event_pump"
require_relative "push_nudge_step"

module Hecks
  module QualityControlCli
    class QaTick
      # The tick's last finding step: the event pump, which runs each attached domain's policies
      # on the events its cursors have not yet read.
      module EventPumpStep
        include PushNudgeStep

        private

        # @return [Array<Step>] the pump's step when the `event_pump` dial is on, else none
        def pump_steps
          dial(:EVENT_PUMP, false) ? [Step.new("event_pump", *run_event_pump)] : []
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
