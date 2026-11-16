# frozen_string_literal: true

require "json"

module Hecks
  module Adapters
    module PipelineBoard
      # Gathers what the planning tile draws from the readers the board holds, once per drawing,
      # and hands it to {PlanReading}. The tickets reader answers from the store and the jobs
      # reader from files, so a drawing launches nothing.
      module PlanTile
        # @return [Hash] the planning page's reading, or `{unknown: reason}`
        def plan_tile = guard { plan_reading }

        private

        def plan_reading
          items = JSON.parse(@tickets.open_work[:text], symbolize_names: true)
          PipelineBoard::PlanReading.build(items: items, epics: @tickets.epics, sessions: plan_sessions(items),
                                           reviews: plan_reviews(items), fill: plan_fill, train: train_tile, now: @now.call,
                                           flow: guard { @tickets.work_times })
        end

        def plan_sessions(items)
          rows = JSON.parse(@jobs.sessions[:text], symbolize_names: true)
          PipelineBoard::OwnerQueue.mark(rows, items, ENV.fetch("PIPELINE_BOARD_LAUNCHER_ROOT", @root))
        end

        # Only the reviews of work still open are read: a review shows on its item's row, and a finished
        # item's row carries none, so the hundreds of finished items' transcripts are never parsed.
        def plan_reviews(items)
          found = PipelineBoard::AgentRoles.reviews(open_runs(guard { @tickets.runs }, items))
          found.is_a?(Array) ? found : []
        end

        def open_runs(runs, items)
          return runs unless runs.is_a?(Hash) && !runs.key?(:unknown)

          open = items.to_set { |item| item[:slug].to_s }
          runs.select { |_, run| open.include?(run[:work_item].to_s) }
        end

        def plan_fill
          found = guard { @fill.preview }
          found.key?(:unknown) ? { would_start: [], skipped: [] } : found
        end
      end
    end
  end
end
