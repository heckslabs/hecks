# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # When each Work item finished, as the Tickets store's own event log records it: the log
      # goes back as far as the store does, where the event tap keeps only its last hours. Read
      # from the live store when the board is told where it is, else from the booted registry.
      # Mixed into {PipelineTickets}, which supplies the stores it reads.
      module FinishedTimes
        # The event a finished Work item emits.
        FINISHED = "WorkFinished"

        # @return [Array<String>] the time of every `WorkFinished` the store holds, oldest first;
        #   none when the store keeps no event log (Memory)
        def finished_times
          return @finished if @finished

          logged = @live ? @live.events("Tickets", "Work") : @own.events("Tickets", "Work")
          logged.select { |event| event.name.to_s == FINISHED }.map { |event| event.occurred_at.to_s }
        end
      end
    end
  end
end
