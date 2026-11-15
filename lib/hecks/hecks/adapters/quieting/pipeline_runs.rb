# frozen_string_literal: true

require_relative "../shell"
require_relative "../dispatching/work_items"

module Hecks
  module Adapters
    class Quieting
      # The agent runs that are live, their sessions stopped, and the Work items they held
      # returned to
      # the plan. A session the owner works in has no run, so it is never touched, and it is named
      # so
      # the report can say what was left running.
      class PipelineRuns
        # The reason a held item gives for going back to the plan.
        REASON = "a merge window was opened: the pipeline is held so a train can merge"

        # @param registry [Runtime::Registry, nil] whose runs and Work items are read
        # @param stop [#call, nil] stops one session by its id
        # @param yield_back [#call, nil] returns one Work item to the plan, with a reason
        # @param root [String] the checkout whose `exe/hecks` runs the yield
        def initialize(registry, stop: nil, yield_back: nil, root: Dir.pwd)
          @items = Dispatching::WorkItems.new(registry)
          @stop = stop || ->(session) { Shell.new.capture("claude", "stop", session) }
          @yield_back = yield_back || ->(key) { yield_argv(root, key) }
        end

        # @return [Hash{String => String}] each live run's key with the session it holds
        def live
          @items.runs.select { |_, run| run[:status] == "started" && !run[:session].to_s.empty? }
                .transform_values { |run| run[:session] }
        end

        # Stops the session of every live run and returns the items they held to the plan.
        #
        # @return [Hash{Symbol => Array<String>}] `sessions:` the ids stopped and `items:` the keys
        #   returned to the plan
        def stop_all
          held = live
          held.each_value { |session| @stop.call(session) }
          started = @items.started.map(&:key)
          returned = held.keys.select { |key| started.include?(key) }
          returned.each { |key| @yield_back.call(key) }
          { sessions: held.values, items: returned }
        end

        private

        def yield_argv(root, key)
          Shell.new.capture("exe/hecks", "tickets", "Work.yield!", "to=#{key}", "reason.value=#{REASON}", "--wait",
                            chdir: root)
        end
      end
    end
  end
end
