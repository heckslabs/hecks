# frozen_string_literal: true

require_relative "batching"

module Hecks
  module Adapters
    class Dispatching
      # The launch steps a lead's batch adds: after the lead starts, each member is held in its
      # batch by `Work.Enlist`, and the started line names the group. It runs the steps of the
      # {Launcher} that includes it.
      module BatchSteps
        private

        # Holds each member of a lead's batch, after the lead started: a hold that fails yields the
        # lead, and the Tickets bluebook then lets go of every member it held.
        def enlist(item)
          Array(item.batched).each do |member|
            step(item, "enlist #{member.key}",
                 ["tickets", "Work.enlist!", "to=#{member.key}", "batch.value=#{item.key}", "--wait"])
          end
        end

        # The started line, opened by the group's name and size when the item leads one.
        def group_line(item, line) = item.group ? "starting #{Batching.name_of(item)}: #{line}" : line
      end
    end
  end
end
