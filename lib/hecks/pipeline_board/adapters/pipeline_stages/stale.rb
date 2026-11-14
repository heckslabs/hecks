# frozen_string_literal: true

require "time"

module Hecks
  module Adapters
    module PipelineBoard
      # What a section shows when its read was skipped: the last answer the reader gave, with the
      # time that answer was read. A read is skipped when it missed its bound, is still running
      # from an earlier refresh, failed, or was not started because the machine is loaded. The
      # reader is not asked a second time in the same refresh; the next refresh asks once more.
      module Stale
        # @return [Hash{Symbol => Hash}] each section showing an earlier answer: `since` (when
        #   that answer was read) and `reason` (why this refresh has none)
        def stale_sections = (@stale ||= {}).dup

        private

        # The answer the section shows: this refresh's, else the last good one, noted as stale.
        # A section never answered keeps its `{unknown: reason}`.
        def lasting(section, answer)
          return fresh(section, answer) unless unanswered?(answer)

          good = (@good ||= {})[section]
          return answer unless good

          (@stale ||= {})[section] = { since: good.last, reason: answer[:unknown] }
          good.first
        end

        def fresh(section, answer)
          (@good ||= {})[section] = [answer, Time.now.utc.iso8601]
          (@stale ||= {}).delete(section)
          answer
        end

        def unanswered?(answer) = answer.is_a?(Hash) && answer.key?(:unknown)
      end
    end
  end
end
