# frozen_string_literal: true

require_relative "../iteration_watch"

module Hecks
  module Adapters
    class SettingsReading
      # The `iteration watch` row of `hecks config`: when a started Work row counts as bloated, and
      # whether the Tickets world or the defaults say so.
      module IterationWatchRow
        # @param directory [String] the domain directory
        # @return [Array(String, String, String)] the row's name, value and source
        def iteration_watch(directory)
          registry = Hecks.describe(directory).registry
          limits = IterationWatch::Setting.read(registry)
          source = IterationWatch::Setting.declared(registry).empty? ? "default" : "world"
          ["iteration watch", wording(limits), source]
        rescue StandardError => e
          ["iteration watch", "could not be read", first_line(e.message)]
        end

        private

        def wording(limits)
          "#{limits.attempts} attempts, #{limits.wait_minutes} minutes waiting, #{limits.over_budget} times budget " \
            "(#{limits.default_budget_minutes} minutes when none)"
        end
      end
    end
  end
end
