# frozen_string_literal: true

require_relative "quieting/landing_trees"
require_relative "quieting/pipeline_runs"

module Hecks
  module Adapters
    # The `Quieting` port's adapter for `MergeWindow`: stops the pipeline's sessions, returns the
    # work
    # they held to the plan and ends the landings in flight, and answers what it did as one line.
    #
    # It decides nothing. That a window pauses the fill is the settings' rule, read from the
    # window's
    # own record; this only does what opening a window is for, and says what it did. It never
    # touches a
    # branch, a commit or a worktree, and never a session that holds no run.
    class Quieting
      # @param registry [Runtime::Registry, nil] whose runs and Work items are read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] stand-ins: `runs:` and `trees:` replace the two doers
      # @param root [String, nil] the checkout whose `exe/hecks` runs a yield
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @runs = settings[:runs] || PipelineRuns.new(registry, root: root || Dir.pwd)
        @trees = settings[:trees] || LandingTrees.new
      end

      # @param held [Hash] the `MergeWindow` record: `run`
      # @return [Hash{Symbol => Hash}] `quieted:` what it stopped, returned and ended
      def quiet(**_held)
        stopped = @runs.stop_all
        ended = @trees.end_all
        { quieted: { value: line(stopped, ended) } }
      end

      private

      def already(gone) = gone.to_a.empty? ? "" : " (#{gone.size} already stopped)"

      def line(stopped, ended)
        "stopped #{stopped[:sessions].size} pipeline sessions#{already(stopped[:gone])}, " \
          "returned #{stopped[:items].size} work items to the plan, " \
          "ended #{ended.size} landing processes; branches and commits kept"
      end
    end
  end
end
