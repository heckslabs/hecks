# frozen_string_literal: true

require "json"
require_relative "../started_work"

module Hecks
  module Adapters
    class MachineSampling
      # The stored readings' consumers read per day: for each purpose, the mean percent of one core
      # over the day's readings (a reading that names no CPU for a purpose counts zero for it).
      class PurposeDays
        # @param records [Array<#[]>] stored `Machine` readings, with `taken_at` and `consumers`
        def initialize(records)
          @records = records
        end

        # @return [Array<Hash>] `day`, `purpose`, `cpu` (mean) and `readings` per day and purpose
        def rows
          days = counted.group_by { |day, _| day }
          days.flat_map { |day, held| per_purpose(day, held.map(&:last)) }
        end

        private

        # Each reading that records consumers, as its day and its rows.
        def counted
          @records.filter_map do |record|
            text = StartedWork.value(record, :consumers).to_s
            stamp = StartedWork.value(record, :taken_at).to_s
            [stamp[0, 10], JSON.parse(text)] unless text.empty? || stamp.empty?
          end
        end

        def per_purpose(day, readings)
          purposes = readings.flatten.map { |row| row["purpose"] }.uniq
          purposes.map do |purpose|
            sum = readings.sum { |rows| rows.sum { |row| row["purpose"] == purpose ? row["cpu"] : 0 } }
            { day: day, purpose: purpose, cpu: (sum / readings.size).round(1), readings: readings.size }
          end
        end
      end
    end
  end
end
