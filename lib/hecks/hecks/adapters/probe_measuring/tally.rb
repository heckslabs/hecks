# frozen_string_literal: true

require "time"

module Hecks
  module Adapters
    class ProbeMeasuring
      # Counts the pipeline over one stretch of time from event log rows (`at`, `name`, `id`): work
      # items started, branches landed, work items yielded within five minutes of their start, and
      # the age in seconds of the oldest block still unanswered when the stretch ends.
      module Tally
        # The event names a tally reads.
        NAMES = %w[WorkStarted WorkYielded BranchLanded SessionBlocked AgentResumed AgentRunUnanswered].freeze

        # A yield this soon after its start counts as quick.
        QUICK = 300

        # The events that answer a block.
        ANSWERS = %w[AgentResumed AgentRunUnanswered].freeze

        module_function

        # @param rows [Array<Hash>] the log's rows of {Tally::NAMES}, oldest first
        # @param from [Integer] where the stretch starts, in epoch seconds
        # @param to [Integer] where it ends, in epoch seconds
        # @return [Hash{Symbol => Hash}] `starts`, `landings`, `yields` and `block`, each `{value:}`
        def of(rows, from, to)
          timed = rows.filter_map { |row| stamped(row) }
          inside = timed.select { |row| row[:at] > from && row[:at] <= to }
          { starts: counted(named(inside, "WorkStarted").size), landings: counted(named(inside, "BranchLanded").size),
            yields: counted(quick_yields(timed, inside)), block: counted(oldest_block(timed, to)) }
        end

        # Yields inside the stretch whose work item started at most {Tally::QUICK} seconds before.
        def quick_yields(timed, inside)
          starts = named(timed, "WorkStarted")
          named(inside, "WorkYielded").count do |row|
            starts.any? { |start| start[:id] == row[:id] && (row[:at] - start[:at]).between?(0, QUICK) }
          end
        end

        # The age at `to` of the oldest block raised by then and not answered by then; 0 for none.
        def oldest_block(timed, to)
          raised = open_blocks(timed.select { |row| row[:at] <= to })
          raised.empty? ? 0 : to - raised.min
        end

        # When each run's last block was raised, for the runs no later answer reached.
        def open_blocks(seen)
          answers = seen.select { |row| ANSWERS.include?(row[:name]) }
          named(seen, "SessionBlocked").group_by { |row| row[:id] }.filter_map do |id, blocks|
            raised = blocks.last[:at]
            raised unless answers.any? { |row| row[:id] == id && row[:at] >= raised }
          end
        end

        def named(rows, name) = rows.select { |row| row[:name] == name }

        def stamped(row)
          row.merge(at: Time.iso8601(row[:at].to_s).to_i, name: row[:name].to_s.split(".").last)
        rescue ArgumentError
          nil
        end

        def counted(number) = { value: number }
      end
    end
  end
end
