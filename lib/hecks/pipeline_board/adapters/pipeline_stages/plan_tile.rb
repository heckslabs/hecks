# frozen_string_literal: true

require "json"
require_relative "plan_summary"

module Hecks
  module Adapters
    module PipelineBoard
      # Gathers what the planning tile draws from the readers the board holds, once per drawing,
      # and hands it to {PlanReading}. The tickets reader answers from the store and the jobs
      # reader from files, so a drawing launches nothing.
      module PlanTile
        # How many epics the summary names.
        PLAN_EPICS = 5

        # @return [Hash] the planning page's reading, or `{unknown: reason}`
        def plan_tile = guard { plan_reading }

        # Another project's planning tile: its epics and undone items, read from its own store.
        # The sessions, the fill, the plan reviews and the train are the board's own project's,
        # so none is shown beside another's work.
        #
        # @param name [String] a `ProjectBoard` name
        # @return [Hash] the reading, or `{unknown: reason}`
        def project_plan_tile(name) = guard { project_plan_reading(name) }

        # The plan's counts as the Tickets events keep them: no Work item is read to answer it.
        #
        # @param running [Array<String>] the slugs of Work items a session runs
        # @return [Hash, nil] `done`, `open`, `epics`, `lanes` and `first_epics`; nil when the
        #   tickets reader does not offer the plan's events, so the caller counts the items itself
        def plan_summary(running: [])
          held = held_plan_summary or return nil

          held.summary(running: running).merge(first_epics: held.first_epics(PLAN_EPICS))
        end

        private

        # @return [PlanSummary, nil] the one kept summary, caught up with the events past its cursor
        def held_plan_summary
          return nil unless @tickets.respond_to?(:plan_events)

          events = guard { @tickets.plan_events }
          return nil if events.key?(:unknown)

          (@plan_summary ||= PipelineBoard::PlanSummary.new).catch_up(:work, events[:work]).catch_up(:epic, events[:epic])
        end

        # A reader's own rows as plain data, as the page reads them.
        def plain(rows) = JSON.parse(JSON.generate(rows), symbolize_names: true)

        def plan_reading
          items = plain(@tickets.undone_work)
          reading = plan_built(items)
          held = plan_summary(running: reading[:strip][:running].map { |row| row[:slug] })
          held ? reading.merge(summary: held.except(:first_epics)) : reading
        end

        def plan_built(items)
          PipelineBoard::PlanReading.build(items: items, epics: @tickets.epics, sessions: plan_sessions(items),
                                           reviews: plan_reviews(items), fill: plan_fill, train: train_tile, now: @now.call,
                                           flow: guard { @tickets.work_times })
        end

        def project_plan_reading(name)
          read = plain(@tickets.project_plan(name))
          return read if read.key?(:unknown)

          PipelineBoard::PlanReading.build(items: read[:items], epics: read[:epics], sessions: [], reviews: [],
                                           fill: { would_start: [], skipped: [] }, train: nil, now: @now.call, flow: nil)
        end

        def plan_sessions(items)
          rows = plain(@jobs.rows)
          PipelineBoard::OwnerQueue.mark(rows, items, ENV.fetch("PIPELINE_BOARD_LAUNCHER_ROOT", @root))
        end

        # Only the reviews of work still open are read: a review shows on its item's row, and a
        # finished item's row carries none, so the hundreds of finished items' transcripts are
        # never parsed.
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
