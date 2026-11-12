# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # The planning page, answered by the board's web adapter at `/plan`.
      module PlanPage
        # The page file, which holds a `<!--tile:plan-->` mark where the plan tile is drawn.
        PATH = File.expand_path("plan.html", __dir__)

        # @return [String] the planning page, with the plan tile drawn into its place
        def plan_page = @pushed.page(File.read(PATH))
      end
    end

    # Reopened here so the planning page's reader sits beside the page it reads.
    class PipelineWeb
      include PipelineBoard::PlanPage
    end
  end
end
