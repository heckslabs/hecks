# frozen_string_literal: true

module Hecks
  module Adapters
    class IterationWatch
      # The events that belong to one Work row since its claim. The row's key is its branch and
      # its worktree is that key with the slash made a dash, so an event belongs to the row when
      # it names either, or when it comes from a record (a landing run, an agent run) that does.
      class Mine
        # @param key [String] the Work row's key
        # @param claimed_at [Time, nil] when the claim was taken; every event counts when nil
        # @param events [Array<Log::Event>] the whole log
        def initialize(key, claimed_at, events)
          @claimed_at = claimed_at
          @names = Regexp.union([key, key.tr("/", "-")].map { |name| /(?<![\w\/-])#{Regexp.escape(name)}(?![\w\/-])/ })
          @key = key
          @events = events
        end

        # @return [Array<Log::Event>] the row's events since its claim, oldest first
        def events
          runs = @events.select { |event| event.text.match?(@names) }.map(&:aggregate_id) << @key
          @events.select { |event| since?(event) && (runs.include?(event.aggregate_id) || event.text.match?(@names)) }
        end

        private

        def since?(event) = @claimed_at.nil? || event.at >= @claimed_at
      end
    end
  end
end
