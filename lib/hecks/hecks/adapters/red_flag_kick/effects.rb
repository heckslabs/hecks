# frozen_string_literal: true

require "hecks/runtime/dispatcher"

module Hecks
  module Adapters
    class RedFlagKick
      # The commands a kick runs once its restore is on the branch: the landing, the train, the
      # Work item, the coder's brief and dispatch, the retirement, and the flag's own record of
      # the kick and of the lowering (a flag raised deep in CI's saga has no reaction depth left
      # for them). Each is a dispatch of its
      # own, as an operator would make it, so the reaction depth the kick's policy reached does
      # not count against it. A spec replaces any step with a callable that takes the same keywords.
      class Effects
        # The verb each step dispatches.
        VERBS = {
          land:     "Hecks::Landing.Finish",
          board:    "Hecks::SendTrain.Board",
          plan:     "Tickets::Work.Plan",
          brief:    "Coder::Brief.Compose",
          dispatch: "Hecks::AgentRun.Dispatch",
          retire:   "Hecks::Landing.Retire",
          eject:    "Hecks::RedFlag.Eject",
          lift:     "Hecks::RedFlag.Lift"
        }.freeze

        # @param registry [Runtime::Registry, nil] the booted registry the steps dispatch through
        # @param overrides [Hash{Symbol => #call}] steps replaced for a spec, by name
        def initialize(registry, overrides = {})
          @registry = registry
          @overrides = overrides
        end

        # @param step [Symbol] a key of `VERBS`
        # @param args [Hash] the keywords the step's command takes
        # @return [Object] whatever the step answers
        def run(step, **args)
          replaced = @overrides[step]
          return replaced.call(**args) if replaced

          top_level(VERBS.fetch(step), **args)
        end

        private

        def top_level(verb, **args)
          depth = Thread.current[:hecks_reaction_depth]
          Thread.current[:hecks_reaction_depth] = 0
          Runtime::Dispatcher.new(@registry).dispatch_flat(verb, args)
        ensure
          Thread.current[:hecks_reaction_depth] = depth
        end
      end
    end
  end
end
