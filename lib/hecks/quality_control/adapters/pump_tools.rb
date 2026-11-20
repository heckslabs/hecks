# frozen_string_literal: true

require_relative "qa_tool"

module Hecks
  module Adapters
    # The adapter QualityControl binds to EventDelivery's `Pumping` port: answers a `Pump.Run` by
    # running the QA ledger's event pump once, as its own process, over the domains the pump
    # attaches. An answer of 0 is a pump that ran, refusals included; anything else is an
    # operational error and is refused with its report.
    class PumpTools < QaTool
      # @param run [Hash, String, nil] the pump run's name; the pump itself takes no arguments
      # @param _held [Hash] the rest of the run's held state, which the ask hands over and the pump
      #   does not read
      # @return [Hash] `text:` what the pump printed
      def carry(run: nil, **_held)
        run_command("qa_event_pump", answers: [0])
      end
    end
  end
end
