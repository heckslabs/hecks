# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # The planning page, answered by the board's web adapter at `/plan`. The page is drawn from
      # the plan tile once and held for {FRESH_SECONDS}; a request after that is answered with the
      # held page at once while one background draw makes the next, so a request never waits on the
      # readers or on the lock a journal redraw holds. Only the first request draws in line.
      module PlanPage
        # The page file, which holds a `<!--tile:plan-->` mark where the plan tile is drawn.
        PATH = File.expand_path("plan.html", __dir__)
        # Seconds a drawn page is served without drawing again.
        FRESH_SECONDS = 10

        # @return [String] the planning page, with the plan tile drawn into its place
        def plan_page
          held = @plan_held
          return draw_plan_page unless held

          redraw_plan_page if monotonic - held[:at] >= FRESH_SECONDS
          held[:html]
        end

        private

        def draw_plan_page
          html = @pushed.page(File.read(PATH))
          @plan_held = { html: html, at: monotonic }
          html
        end

        # Starts the one background draw; a request that finds one going starts none.
        def redraw_plan_page
          return if @plan_drawing

          @plan_drawing = true
          Thread.new { redraw_and_release }.report_on_exception = false
        end

        # A draw that raises leaves the held page as it was.
        def redraw_and_release
          draw_plan_page
        rescue StandardError
          nil
        ensure
          @plan_drawing = false
        end

        def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end

    # Reopened here so the planning page's reader sits beside the page it reads.
    class PipelineWeb
      include PipelineBoard::PlanPage
    end
  end
end
