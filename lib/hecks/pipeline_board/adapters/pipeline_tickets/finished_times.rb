# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # When each Work item was planned, finished and dropped, as the Tickets store's own event log
      # records it: the log goes back as far as the store does, where the event tap keeps only its
      # last hours. Read from the live store when the board is told where it is, else from the
      # booted registry. Mixed into {PipelineTickets}, which supplies the stores it reads.
      module FinishedTimes
        # The event a finished Work item emits.
        FINISHED = "WorkFinished"
        # The events that move the plan, each with what the page counts it as.
        FLOW = { "WorkPlanned" => :planned, FINISHED => :finished, "WorkDropped" => :dropped }.freeze

        # @return [Array<String>] the time of every `WorkFinished` the store holds, oldest first;
        #   none when the store keeps no event log (Memory)
        def finished_times = @finished || work_times[:finished]

        # @return [Hash{Symbol => Array<String>}] `planned`, `finished` and `dropped`: the times of
        #   those events, oldest first; each empty when the store keeps no event log
        def work_times
          return @work_times if @work_times

          logged = @live ? @live.events("Tickets", "Work") : @own.events("Tickets", "Work")
          logged.each_with_object(FLOW.values.to_h { |kind| [kind, []] }) do |event, held|
            kind = FLOW[event.name.to_s]
            held[kind] << event.occurred_at.to_s if kind
          end
        end
      end
    end
  end
end
