# frozen_string_literal: true

require "hecks/roundhouse/adapters/metering"
require_relative "reaping_switch"
require_relative "reap_facts"
require_relative "signalbox_reap"
require_relative "../dispatching/signalbox_door"

module Hecks
  module Adapters
    class ClaudeCleaning
      # Builds the {SignalboxReap} a reap hands to once `reaping.signalbox` is on: Signalbox's door,
      # Roundhouse's `Ended` meter, and the `claude rm` and retire guard that carry out its rulings.
      # `@tuning` may stand in for the outside with `signalbox:` (the door), `meter:` (the meter)
      # and `retire:` (the retire guard).
      #
      # It needs the including adapter's `@registry`, `@tuning`, `@transcript`, `@worktrees`,
      # `@runs`, `@shell`, `window` and `refusal_of`.
      module SignalboxWiring
        private

        def signalbox_report = { report: { value: signalbox_reap.report } }

        def signalbox_removable = { text: "#{signalbox_lines(signalbox_reap.verdicts).join("\n")}\n" }

        def signalbox_reap
          SignalboxReap.new(door: door, meter: @tuning[:meter] || -> { Metering.new(registry: @registry).ended_facts },
                            facts: reap_facts, remove: method(:refusal_of), retire: @tuning[:retire] || method(:retired))
        end

        def door = @tuning[:signalbox] || Dispatching::SignalboxDoor.shared

        def reap_facts
          sources = ReapFacts::Sources.new(window: window, jobs: ClaudeJobs.from(@tuning), transcript: @transcript,
                                           worktrees: @worktrees, runs: @runs, hold: hold)
          ReapFacts.new(sources, { **door.setting("reaping"), fuses: door.setting("fuses") })
        end

        # @return [String, nil] why the copy was kept, nil once it is retired and pruned
        def retired(path)
          SessionReaping.new(registry: @registry, shell: @shell).retire(path)
          @shell.capture("git", "worktree", "prune")
          nil
        rescue ConsoleCapture::Failure => e
          "the retire guard refused: #{e.message}"
        end

        def signalbox_lines(result)
          refused = result.refused ? ["signalbox reap refused: #{result.refused}"] : []
          refused + result.removed.map { |id| "#{id}  reap" } + result.retired.map { |branch| "#{branch}  retire" } +
            result.kept.map { |name, why| "#{name}  kept: #{why}" }
        end
      end
    end
  end
end
