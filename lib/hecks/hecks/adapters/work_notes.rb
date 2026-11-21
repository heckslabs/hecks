# frozen_string_literal: true

require_relative "started_work"
require_relative "console_capture"

module Hecks
  module Adapters
    # The `WorkNotes` port's adapter for `Tickets::Work`: the detail of a work item with a dated
    # note after it. It joins text, which a bluebook rule cannot, and reads the item's current
    # detail from the booted registry. It writes nothing: setting the detail is the bluebook's.
    class WorkNotes
      # @param registry [Runtime::Registry, nil] the booted registry whose Work items are read
      # @param aggregate [Object, nil] unused
      def initialize(registry: nil, aggregate: nil)
        @registry = registry
      end

      # @param held [Hash] the Work item `work`, the `note` and the `dated` day
      # @return [Hash{Symbol => Hash}] `detail:` the item's detail, a blank line, then `on: note`
      # @raise [ConsoleCapture::Failure] naming the work item when it is not recorded
      def compose_note(**held)
        key = plain(held[:work]).to_s
        record = record_of(key)
        raise ConsoleCapture::Failure, "no work item is named #{key}" unless record

        line = "#{plain(held[:dated])}: #{plain(held[:note])}"
        { detail: { value: [StartedWork.value(record, :detail).to_s, line].reject(&:empty?).join("\n\n") } }
      end

      private

      def record_of(key)
        aggregate = StartedWork.work_aggregate(@registry)
        return unless aggregate

        @registry.repository("Tickets", aggregate).all.find { |item| StartedWork.value(item, :work).to_s == key }
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
