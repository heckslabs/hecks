# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # The admissions a fill ruled on just before it started a work item, so the start's own check
      # (`WorkLimits.CheckCap`, asked after `WorkStarted`) keeps that ruling instead of reading a
      # second beat that may stand on the other side of a mark. A grant is the process's, names one
      # work item, is taken once and lapses after the ramp window; a refused admission leaves none.
      module AdmissionGrants
        @lock = Mutex.new
        @granted = {}

        class << self
          # @param key [String] the work item the fill admitted
          # @param at [Time] when it was admitted
          # @return [void]
          def grant(key, at: Time.now) = @lock.synchronize { @granted[key] = at }

          # Takes the work item's grant, which then holds no more.
          #
          # @param key [String] the work item being checked
          # @param within [Integer] the seconds a grant holds, the ramp window
          # @param now [Time] the time of the check
          # @return [Boolean] whether a grant for that work item stood inside the window
          def take?(key, within:, now: Time.now)
            at = @lock.synchronize { @granted.delete(key) }
            !at.nil? && now - at <= within
          end

          # @return [void] drops every grant
          def clear! = @lock.synchronize { @granted.clear }
        end
      end
    end
  end
end
