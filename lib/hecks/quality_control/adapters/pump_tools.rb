# frozen_string_literal: true

require_relative "qa_tool"

module Hecks
  module Adapters
    # The `PumpTools` port's adapter: answers an `EventPump`'s request by running the pump once, as
    # its own process. An answer of 0 is a pump that ran, refusals included; anything else is an
    # operational error and is refused with its report.
    class PumpTools < QaTool
      # @param run [Hash, String, nil] the pump run's name; the pump itself takes no arguments
      # @return [Hash] `text:` what the pump printed
      def execute(run: nil)
        run_command("qa_event_pump", answers: [0])
      end
    end
  end
end
