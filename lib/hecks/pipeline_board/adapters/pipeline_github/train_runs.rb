# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # CI as it ran on the pull requests of the push train. `gh run list` cannot filter by branch
      # prefix, so a wider page is read and the `train/` branches kept. A rerun reuses its run's id
      # and carries the last attempt's finish time, so its wall time is not the run's: only first
      # attempts are listed.
      module TrainRuns
        # How many runs one `gh` page holds before the train branches are picked out of it.
        PAGE = 100

        # Branch prefix of the push train's pull requests.
        TRAIN_PREFIX = "train/"

        private

        def train_rows(limit)
          kept = train_page.select { |run| train_first?(run) }.first(limit)
          kept.reverse.map { |run| Thread.new { row(run) } }.map(&:value)
        end

        def train_page
          read("run", "list", "--workflow", self.class::WORKFLOW, "--event", "pull_request",
               "--limit", PAGE.to_s, "--json", "#{PipelineRuns::RUN_FIELDS},headBranch,attempt")
        end

        def train_first?(run)
          run["headBranch"].to_s.start_with?(TRAIN_PREFIX) && run["attempt"].to_i <= 1
        end

        def train_slowest(limit)
          done = train_page.find { |run| train_first?(run) && run["status"] == "completed" }
          slowest_of(done, limit)
        end
      end
    end
  end
end
