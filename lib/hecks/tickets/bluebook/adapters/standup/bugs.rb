# frozen_string_literal: true

module Hecks
  module Adapters
    class Standup
      # The bugs the zero-bug policy watches, counted from the Work records: those open now and
      # those among the finished work items.
      class Bugs
        # The category a bug is filed under.
        CATEGORY = "bug"

        # The statuses that count as open.
        OPEN = %w[planned started batched].freeze

        # @param records [Array<Object>] the Work records
        # @param finished [Array<String>, nil] the keys finished since the window began
        def initialize(records, finished)
          @bugs = records.select { |record| StartedWork.value(record, :category) == CATEGORY }
          @finished = finished.to_a
        end

        # @return [Array<String>] `open: n` and `finished: n`
        def lines = ["open: #{open.size}", "finished: #{done.size}"]

        private

        def open = @bugs.select { |bug| OPEN.include?(StartedWork.value(bug, :status)) }

        def done = @bugs.select { |bug| @finished.include?(StartedWork.value(bug, :work).to_s) }
      end
    end
  end
end
