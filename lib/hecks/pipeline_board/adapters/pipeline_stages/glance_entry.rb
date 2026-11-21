# frozen_string_literal: true

require_relative "../rules"

module Hecks
  module Adapters
    module PipelineBoard
      # One `StuckItem` of the `Glance`, written from the `StuckKind` row of its kind: the row gives
      # the group, who the item waits on (and whether that is a role or a person) and the line's
      # wording; the adapter only supplies what it read.
      module GlanceEntry
        module_function

        # @param kind [String] a `StuckKind`
        # @param what [String] the fact the line says, put into the row's `says`
        # @param since [String] when it began, as a time
        # @param run [String] the run that owns it
        # @param link [String] where the board shows it
        # @return [Hash] the `StuckItem` row
        def of(kind, what, since: "", run: "", link: "")
          row = Rules.rows("StuckKind").find { |held| held[:kind] == kind }
          { kind: kind, group: row[:group], what: format(row[:says], what: what), since: since.to_s,
            waits_on: row[:waits_on], waits_on_kind: row[:waits_on_kind], owner_run: run.to_s, link: link.to_s }
        end

        # @param item [Hash] a `StuckItem` as `StuckRows` built it
        # @return [Hash] the same item as the row of its kind writes it
        def from(item)
          of(item[:kind], item[:what], since: item[:since], run: item[:owner_run], link: item[:link])
        end
      end
    end
  end
end
