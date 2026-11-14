# frozen_string_literal: true

module Hecks
  module Adapters
    class OutcomeReadings
      # The epic whose outcome is read: the measure row it names and the work item a miss of it
      # would be planned as, read from the booted registry. It reads and never writes.
      class Subject
        # @return [String] the epic's key
        attr_reader :key

        # @param registry [Runtime::Registry, nil] the booted registry
        # @return [Object, nil] the Epic aggregate, nil when no Tickets bluebook is booted
        def self.epic_aggregate(registry)
          aggregates = registry&.bluebook("Tickets")&.aggregates
          Array(aggregates).find { |candidate| candidate.hecks_name == "Epic" }
        end

        # @param registry [Runtime::Registry, nil] the booted registry
        # @param key [String] the epic's key
        def initialize(registry, key)
          @registry = registry
          @key = key
        end

        # @param rows [Array<Hash>] the `OutcomeMeasure` rows
        # @return [Hash] the row the epic names
        # @raise [ConsoleCapture::Failure] when the epic names no measure, or one no row carries
        def row(rows)
          name = measure
          raise ConsoleCapture::Failure, "#{key} states no measure: #{naming(rows)}" if name.empty?

          rows.find { |row| row[:measure] == name } ||
            raise(ConsoleCapture::Failure, "#{name} names no OutcomeMeasure row: #{naming(rows)}")
        end

        # @return [String] the next `<epic>-outcome-<n>` no work item holds
        def finding
          taken = work_keys.filter_map { |work| work[/\A#{Regexp.escape(key)}-outcome-(\d+)\z/, 1]&.to_i }
          "#{key}-outcome-#{taken.max.to_i + 1}"
        end

        # @return [String] how the outcome is read again
        def again = "Epic.review! to=#{key} measures again."

        private

        def naming(rows)
          "Epic.measure_by! to=#{key} measure.value=<row> names one of #{rows.map { |row| row[:measure] }.join(", ")}"
        end

        def measure
          epic = records(self.class.epic_aggregate(@registry)).find { |record| StartedWork.value(record, :epic).to_s == key }
          StartedWork.value(epic, :measure).to_s.strip
        end

        def work_keys = records(StartedWork.work_aggregate(@registry)).map { |record| StartedWork.value(record, :work).to_s }

        def records(aggregate) = aggregate ? @registry.repository("Tickets", aggregate).all : []
      end
    end
  end
end
