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
                                           reviews: plan_reviews, fill: plan_fill, train: train_tile, now: @now.call)
        end

        def plan_sessions(items)
          rows = JSON.parse(@jobs.sessions[:text], symbolize_names: true)
          PipelineBoard::OwnerQueue.mark(rows, items, ENV.fetch("PIPELINE_BOARD_LAUNCHER_ROOT", @root))
        end

        def plan_reviews
          found = PipelineBoard::AgentRoles.reviews(guard { @tickets.runs })
          found.is_a?(Array) ? found : []
        end

        def plan_fill
          found = guard { @fill.preview }
          found.key?(:unknown) ? { would_start: [], skipped: [] } : found
        end
      end
    end
  end
end
