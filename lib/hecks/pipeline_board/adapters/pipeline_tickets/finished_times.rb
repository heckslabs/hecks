# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # When each Work item was planned, finished and dropped, as the Tickets store's own event log
      # records it: the log goes back as far as the store does, where the event tap keeps only its
      # last hours. Read from the live store when the board is told where it is, else from the
      # booted registry. Mixed into {PipelineTickets}, which supplies the stores it reads and
      # `@work_lock`.
      #
      # The times are held, with the position the log was read to, and each refresh reads only the
      # events past it. The position is a count of the store's whole log (a Sqlite store shares one
      # table across aggregates), which is right because the fold keeps only the Work events in
      # {FLOW}. The log is append-only; a store that is swapped or whose log has shrunk (a database
      # replaced) is read again from the start.
      module FinishedTimes
        # The event a finished Work item emits.
        FINISHED = "WorkFinished"
        # The events that move the plan, each with what the page counts it as.
        FLOW = { "WorkPlanned" => :planned, FINISHED => :finished, "WorkDropped" => :dropped }.freeze
        # What nothing has been read into.
        NONE = FLOW.values.to_h { |kind| [kind, [].freeze] }.freeze

        # @return [Array<String>] the time of every `WorkFinished` the store holds, oldest first;
        #   none when the store keeps no event log (Memory)
        def finished_times = @finished || work_times[:finished]

        # @return [Hash{Symbol => Array<String>}] `planned`, `finished` and `dropped`: the times of
        #   those events, oldest first, frozen; each empty when the store keeps no event log
        # @raise [Unavailable] when the store cannot be read; what is held stays as it was
        def work_times
          return @work_times if @work_times

          # The order is always this lock, then the store's: the store never calls back.
          @work_lock.synchronize { read_work_times(@live || @own) }
        end

        private

        def read_work_times(source)
          start, held = held_work(source)
          fresh = source.events_past("Tickets", "Work", start)
          @work_source = source
          @work_position = start + fresh.size
          @work_held = folded(held, fresh)
        end

        # Where the held times stand for this source: nothing read when the source is another one
        # or its log is shorter than what was read. Nothing is changed here, so a read that fails
        # leaves the held times as they were.
        def held_work(source)
          return [0, NONE] unless @work_source.equal?(source)

          source.event_count("Tickets", "Work") < @work_position ? [0, NONE] : [@work_position, @work_held]
        end

        def folded(held, events)
          kept = stamped(events)
          return held if kept.empty?

          grown = held.transform_values(&:dup)
          kept.each { |kind, at| grown[kind] << at }
          grown.transform_values(&:freeze).freeze
        end

        # Each Work event of the plan as what it counts as and its time.
        def stamped(events)
          events.filter_map { |event| [FLOW[event.name.to_s], event.occurred_at.to_s] if FLOW.key?(event.name.to_s) }
        end
      end
    end
  end
end
