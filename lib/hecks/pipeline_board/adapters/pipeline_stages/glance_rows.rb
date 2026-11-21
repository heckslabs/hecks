# frozen_string_literal: true

require_relative "glance_entries"
require_relative "glance_flowing"

module Hecks
  module Adapters
    module PipelineBoard
      # The bluebook's one `Glance` row: what needs a person or stands too long, and whether work is
      # flowing. It reshapes what the readers answered and decides nothing: the `StuckKind`,
      # `Verdict` and `Setting` rows do.
      module GlanceRows
        module_function

        # @param data [Hash] the board's sections as they were read, with the standing `load_guard`
        # @param now [Time] the time the board is read at
        # @return [Hash] one `Glance` row: `entries` and `flowing`
        def build(data, now)
          { entries: GlanceEntries.of(data, now), flowing: GlanceFlowing.of(data) }
        end
      end
    end
  end
end
