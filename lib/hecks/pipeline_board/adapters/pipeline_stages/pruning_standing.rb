# frozen_string_literal: true

require_relative "../probe"
require_relative "../../../hecks/adapters/started_work"

module Hecks
  module Adapters
    module PipelineBoard
      # Whether pruning is paused, as the board shows it: read from the Agents bluebook's `Pruning`
      # seat, which the owner's Pause and Resume steps move. The seat is written by one launcher
      # call and read by the board in another, so it is read from the store the board is given.
      module PruningStanding
        # The role whose seat is read.
        ROLE = "pruner"
        # The step that pauses a seated pruner, and the one taken instead when no seat exists.
        PAUSE = "pause_pruning"
        HOLD = "hold_pruning"
        # The steps that move the seat, after which the board reads it again.
        STEPS = [PAUSE, HOLD, "resume_pruning"].freeze

        module_function

        # @param store [#records] the store that holds the `Pruning` seats
        # @return [Hash] `state` (`paused`, `running` or `unseated`) and the seat's `status`, or
        #   `{unknown: reason}` when the store cannot be read
        def of(store)
          seat = store.records("Agents", "Pruning").find { |found| value(found, :role) == ROLE }
          seat ? seated(value(seat, :status)) : { state: "unseated", status: "" }
        rescue PipelineBoard::Unavailable => e
          { unknown: e.message }
        end

        # @param action [String] the step the page asked for
        # @param standing [Hash, nil] what {of} answered
        # @return [String] the step to take: a pause of an unseated pruner seats it paused
        def step(action, standing)
          action == PAUSE && standing.is_a?(Hash) && standing[:state] == "unseated" ? HOLD : action
        end

        def seated(status) = { state: status == "paused" ? "paused" : "running", status: status }

        def value(record, name) = StartedWork.value(record, name).to_s
      end
    end
  end
end
