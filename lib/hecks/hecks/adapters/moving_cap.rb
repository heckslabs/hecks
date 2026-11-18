# frozen_string_literal: true

require_relative "started_work"
require_relative "machine_sampling/cap_bounds"

module Hecks
  module Adapters
    # Where the moving work cap stands: the `WorkCap` record the Tune bluebook keeps, read only
    # while the owner has the Tickets world's `work_cap` line say `moves: true`. It is a read of a
    # kept record, not a turned setting, so a cap that moves often never retires the resident.
    class MovingCap
      # The one record's key.
      KEY = "pipeline"

      # @param registry [Runtime::Registry, nil] the booted registry holding the WorkCap record
      # @return [Hash, nil] `current`, `least`, `most` and `reason`, the current held inside the
      #   owner's bounds; nil when the cap is fixed or no reading has opened the record
      def self.standing(registry)
        return unless MachineSampling::CapBounds.moving?(registry)

        record = record(registry)
        record && shown(record, MachineSampling::CapBounds.of(registry))
      end

      # @param registry [Runtime::Registry, nil]
      # @return [Integer, nil] the moving cap now, nil when the cap is fixed or unread
      def self.current(registry) = standing(registry)&.fetch(:current)

      # @param registry [Runtime::Registry, nil]
      # @return [Hash, nil] the kept WorkCap record, nil when there is none
      def self.record(registry)
        bluebook = registry&.bluebook("Hecks")
        aggregate = bluebook&.aggregates&.find { |held| held.hecks_name == "WorkCap" }
        aggregate && registry.repository("Hecks", aggregate).find(KEY)
      end

      # @param record [Hash] the WorkCap record
      # @param bounds [Hash] `cap_least` and `cap_most`, as {MachineSampling::CapBounds.of} reads
      # @return [Hash] `current` held inside the bounds, the bounds and the record's `reason`
      def self.shown(record, bounds)
        least = bounds[:cap_least]
        most = bounds[:cap_most]
        current = Integer(StartedWork.value(record, :current) || least).clamp(least, most)
        { current: current, least: least, most: most, reason: StartedWork.value(record, :reason).to_s }
      end
    end
  end
end
